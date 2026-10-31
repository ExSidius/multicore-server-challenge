(* One Eio event loop per domain, each with its own SO_REUSEPORT listener and share of the Postgres connections,
   plus C threads for bcrypt. *)
let getenv k default = match Sys.getenv_opt k with Some v when v <> "" -> v | _ -> default
let getenv_int k default = int_of_string (getenv k (string_of_int default))
let queue_depth = 4096

let serve ~host ~port ~db ~pool_size ~secret domain env : unit =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let app = App.{ pool = Pg.create_pool ~size:pool_size db; secret } in
  let addr = `Tcp (Eio_unix.Net.Ipaddr.of_unix (Unix.inet_addr_of_string host), port) in
  let sock = Eio.Net.listen ~sw ~reuse_addr:true ~reuse_port:true ~backlog:65535 net addr in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.fork ~sw (fun () ->
      Stats.reporter ~clock ~domain ~pool_free:(fun () -> Eio.Stream.length app.pool.q));
  let on_error e = Printf.eprintf "connection error: %s\n%!" (Printexc.to_string e) in
  while true do
    Eio.Net.accept_fork ~sw sock ~on_error (fun flow _ ->
        (match Eio_unix.Resource.fd_opt flow with
        | Some fd -> Eio_unix.Fd.use_exn "nodelay" fd (fun fd -> Unix.setsockopt fd Unix.TCP_NODELAY true)
        | None -> ());
        Http.serve flow (App.handle app))
  done

(* The box doesn't restart anything: a dead worker takes the whole server down, visibly. *)
let die e =
  Printf.eprintf "worker failed: %s\n%!" (Printexc.to_string e);
  Unix._exit 1

let () =
  let host = getenv "HOST" "127.0.0.1" in
  let port = getenv_int "PORT" 3000 in
  let db = Sys.getenv "DATABASE_URL" in
  let secret = Sys.getenv "JWT_SECRET" in
  let workers = max 1 (getenv_int "WORKERS" 6) in
  let pool_size = max 1 (getenv_int "PG_CONNECTIONS" 30 / workers) in
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let serve = serve ~host ~port ~db ~pool_size ~secret in
  try
    Bcrypt.start
      ~threads:(max 1 (getenv_int "BCRYPT_THREADS" 2))
      ~wait_ms:(getenv_int "BCRYPT_WAIT_MS" 400)
      ~nice:(getenv_int "BCRYPT_NICE" 19);
    Eio_linux.run ~queue_depth @@ fun env ->
    for d = 2 to workers do
      ignore (Domain.spawn (fun () -> try Eio_linux.run ~queue_depth (serve d) with e -> die e))
    done;
    serve 1 env
  with e -> die e
