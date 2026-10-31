# OCaml 5: Eio on io_uring, libpq and ppx_deriving_yojson

**Front: direct**

| Piece | Version |
|---|---|
| Language | OCaml 5.4.0 (vanilla compiler), built by `build.sh` into a local opam root, from a pinned opam-repository commit |
| Concurrency | [Eio](https://github.com/ocaml-multicore/eio) 1.6 with `eio_linux` (io_uring): one fiber per connection, one event loop per domain |
| HTTP | ~200 lines in `src/http.ml`: HTTP/1.1, keep-alive, `Content-Length` bodies |
| Postgres | [postgresql-ocaml](https://github.com/mmottl/postgresql-ocaml) 5.4.0 (libpq) in non-blocking mode, awaited through Eio; prepared statements, binary results |
| JSON | [ppx_deriving_yojson](https://github.com/ocaml-ppx/ppx_deriving_yojson) 3.10.0 on Yojson 3.0.0 for requests and most responses; batched reads write their JSON directly (`src/json.ml`), byte-identical |
| bcrypt | C threads hashing up to 5 passwords at once (`src/bcrypt_stubs.c`; kernel and tables after `c-epoll-umitaltintas`, generated assembly after `zig-iouring-nick-potts`), checked against libxcrypt at startup |
| JWT | HS256 from [digestif](https://github.com/mirage/digestif) 1.4.1 |

## Design

- **Domains.** `WORKERS` (default 6) domains each run an event loop with their own `SO_REUSEPORT` listener and share
  of the Postgres connections. `BCRYPT_THREADS` (default 2) plain C threads do the hashing at `BCRYPT_NICE` (default 19).
- **`PG_CONNECTIONS`** (default 30) is split evenly between network domains. A request holds one connection for all
  its statements. The reference SQL runs unchanged and is prepared once per connection.
- **bcrypt never blocks an event loop.** A login's fiber suspends on its job's eventfd. Interleaving 5 hashes costs
  14-29 ms of CPU per hash on the benchmark box, against 51-56 ms alone. A hash waits up to `BCRYPT_WAIT_MS` (default
  400) for others to share its batch, unless no other login arrived recently. Every password still gets its own
  full cost-10 hash, and nothing is kept.

- **Reads and the common writes are batched across domains.** Each kind has a lane: a fiber on one domain with its own connection,
  which takes every request waiting (from any domain), lets more arrive for `BATCH_WINDOW_MS` (default 150), and runs
  them as one statement with array parameters. An article's data is read once however many pages and viewers want it,
  and a viewer's favorites and follows are walked once. Only requests already queued when the statement starts share
  it, and nothing is kept afterwards. Writes in a batch share one statement and one commit, and each response waits
  for that commit. If a batch fails, its requests run alone, so one bad request fails only itself.
- **An article is rendered once per batch.** Each request joins the shared JSON pieces and adds its viewer's two flags.
- **`OCAMLRUNPARAM` trades memory for fewer collections** (`s=8M,o=400`), because each major collection scans every
  fiber's stack. About 3 GB of RSS at 100k users.

## Development

`dev/aws/aws.sh` syncs this folder to two AWS machines and runs builds, conformance and benchmarks there through the
repo's scoring scripts, with telemetry. `CONDUIT_STATS=1` makes each domain print one line of counters per second;
it's off by default. `dev/bench.sh` and `dev/profile.sh` are older single-machine equivalents. None of `dev/` runs in
a scored benchmark.
