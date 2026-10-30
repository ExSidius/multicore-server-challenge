# OCaml 5: Eio on io_uring, libpq and ppx_deriving_yojson

**Front: direct**

| Piece | Version |
|---|---|
| Language | OCaml 5.4.0 (vanilla compiler), built by `build.sh` into a local opam root, from a pinned opam-repository commit |
| Concurrency | [Eio](https://github.com/ocaml-multicore/eio) 1.6 with `eio_linux` (io_uring): one fiber per connection, one event loop per domain |
| HTTP | ~200 lines in `src/http.ml`: HTTP/1.1, keep-alive, `Content-Length` bodies |
| Postgres | [postgresql-ocaml](https://github.com/mmottl/postgresql-ocaml) 5.4.0 (libpq) in non-blocking mode, awaited through Eio; prepared statements, binary results |
| JSON | [ppx_deriving_yojson](https://github.com/ocaml-ppx/ppx_deriving_yojson) 3.10.0 on Yojson 3.0.0: serializers derived from the request and response types |
| bcrypt | libxcrypt `crypt_r` through a small C stub that releases the runtime lock, on an `Eio.Executor_pool` |
| JWT | HS256 from [digestif](https://github.com/mirage/digestif) 1.4.1 |

## Design

- **Domains.** `WORKERS` (default 6) domains each run an event loop with their own `SO_REUSEPORT` listener and share
  of the Postgres connections. With `BCRYPT_DOMAINS` (default 2) that makes 8 domains for 8 cores, the limit Eio's
  documentation recommends. Two bcrypt domains handle about 40 hashes per second, which is the login rate of
  roughly 140,000 users.
- **`PG_CONNECTIONS`** (default 30) is split evenly between network domains. A request holds one connection for all
  its statements. The reference SQL runs unchanged and is prepared once per connection.
- **bcrypt never blocks an event loop.** A login's fiber suspends while a bcrypt domain does the work, and the C
  stub releases the runtime lock so that domain doesn't delay other domains' minor collections.

This is a first prototype: no pipelining, no query batching and no SQL changes yet.

## Development

`dev/aws/aws.sh` syncs this folder to two AWS machines and runs builds, conformance and benchmarks there through the
repo's scoring scripts, with telemetry. `CONDUIT_STATS=1` makes each domain print one line of counters per second;
it's off by default. `dev/bench.sh` and `dev/profile.sh` are older single-machine equivalents. None of `dev/` runs in
a scored benchmark.
