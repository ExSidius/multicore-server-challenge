#!/usr/bin/env bash
# Runs the server in the foreground. WORKERS, BCRYPT_THREADS and PG_CONNECTIONS override the defaults for tuning runs.
set -euo pipefail
cd "$(dirname "$0")"
ulimit -n "$(ulimit -Hn)"
# Postgres is on the same box, over loopback: TLS would only burn CPU on both ends.
export PGSSLMODE="${PGSSLMODE:-disable}"
export OCAMLRUNPARAM="${OCAMLRUNPARAM:-s=32M,o=400}"
if [ "${SCHED_BATCH:-0}" = 1 ]; then exec chrt -b 0 ./_build/default/src/main.exe; fi
exec ./_build/default/src/main.exe
