(* bcrypt cost 10 on a pool of dedicated domains. The calling fiber suspends while a hash runs, so its network
   domain keeps serving other connections. *)
external verify_stub : string -> string -> string = "conduit_bcrypt_verify"
external hash_stub : string -> string = "conduit_bcrypt_hash"

let pool = ref None
let init p = pool := Some p
let offload f = Stats.bcrypt (fun () -> Eio.Executor_pool.submit_exn (Option.get !pool) ~weight:1.0 f)

(* C strings stop at NUL, so a password containing one would be silently truncated: it never matches. *)
let verify ~password ~hash =
  (not (String.contains password '\000'))
  && String.length hash > 0
  &&
  let got = offload (fun () -> verify_stub password hash) in
  String.length got = String.length hash && Eqaf.equal got hash

(* None for a password bcrypt can't represent. *)
let hash password =
  if String.length password > 72 || String.contains password '\000' then None
  else
    match offload (fun () -> hash_stub password) with
    | "" -> failwith "bcrypt: hash failed"
    | h -> Some h
