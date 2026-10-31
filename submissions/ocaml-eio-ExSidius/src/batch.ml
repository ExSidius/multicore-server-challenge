(* A lane batches requests of one kind from every domain into one execution. Its fiber takes whatever is waiting,
   lets more arrive for [window] seconds, and runs them as one statement on its own connection. Only requests already
   queued when the statement starts share it, and nothing is kept afterwards. *)
type ('a, 'b) job = { input : 'a; reply : ('b, exn) result Eio.Promise.u }
type ('a, 'b) t = { q : ('a, 'b) job Eio.Stream.t; window : float; name : string }

let create ~name ~window = { q = Eio.Stream.create max_int; window; name }

(* Eio's stream and promises are safe across domains. *)
let submit t input =
  let p, reply = Eio.Promise.create () in
  Eio.Stream.add t.q { input; reply };
  Eio.Promise.await_exn p

let rec drain q acc = match Eio.Stream.take_nonblocking q with Some j -> drain q (j :: acc) | None -> List.rev acc

(* [f] gets the inputs in order and returns one result per input. *)
let run t ~clock ~url f =
  let conn = ref (Pg.connect url) in
  let jobs_n = ref 0 and runs = ref 0 and last = ref (Stats.now ()) in
  while true do
    let first = Eio.Stream.take t.q in
    Eio.Time.sleep clock t.window;
    let jobs = first :: drain t.q [] in
    if not !conn.alive then conn := Pg.connect url;
    (match f !conn (List.map (fun j -> j.input) jobs) with
    | results -> List.iter2 (fun j r -> Eio.Promise.resolve_ok j.reply r) jobs results
    | exception ((Eio.Cancel.Cancelled _) as e) -> raise e
    | exception e ->
        (* One bad request (say, invalid UTF-8 in a tag) mustn't fail the others: each gets its own answer. *)
        List.iter
          (fun j ->
            if !conn.busy then Pg.discard !conn;
            if not !conn.alive then conn := Pg.connect url;
            match f !conn [ j.input ] with
            | [ r ] -> Eio.Promise.resolve_ok j.reply r
            | _ -> Eio.Promise.resolve_error j.reply e
            | exception e -> Eio.Promise.resolve_error j.reply e)
          jobs);
    if Stats.enabled then begin
      jobs_n := !jobs_n + List.length jobs;
      incr runs;
      let t1 = Stats.now () in
      if t1 -. !last >= 1. then begin
        Printf.eprintf "batch lane=%s runs=%d jobs=%d avg=%.1f\n%!" t.name !runs !jobs_n
          (float !jobs_n /. float !runs);
        jobs_n := 0;
        runs := 0;
        last := t1
      end
    end
  done
