#!/usr/bin/env bash
# Runs the server in the foreground. WORKERS, BCRYPT_DOMAINS and PG_CONNECTIONS override the defaults for tuning runs.
set -euo pipefail
cd "$(dirname "$0")"
ulimit -n "$(ulimit -Hn)"
export OCAMLRUNPARAM="${OCAMLRUNPARAM:-s=1M}"
exec ./_build/default/src/main.exe
