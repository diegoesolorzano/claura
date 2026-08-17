#!/usr/bin/env bash
# tests/run.sh — run every tests/*.sh except this file.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
fail=0
shopt -s nullglob
for t in "$SELF_DIR"/*.sh; do
  [[ "$(basename "$t")" == "run.sh" ]] && continue
  if ! /usr/bin/env bash "$t"; then
    echo "FAIL $t" >&2
    fail=1
  else
    echo "ok   $t"
  fi
done
exit "$fail"
