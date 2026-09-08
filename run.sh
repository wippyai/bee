#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
bee_runtime="${BEE_RUNTIME:-$PWD/.wippy/bin/bee-wippy}"
if [[ ! -x "$bee_runtime" ]]; then
  echo 'Bee development runtime is missing. Run make setup, then make run.' >&2
  exit 1
fi
if [[ "${1:-}" == "--app" ]]; then
  shift
  if [[ $# -eq 0 ]]; then
    echo 'Usage: ./run.sh --app definition-id [application arguments...]' >&2
    exit 2
  fi
  exec "$bee_runtime" run bee-app -- "$@"
fi
exec "$bee_runtime" run bee "$@"
