#!/usr/bin/env bash
# tests/chime.sh — claura-chime.sh play/skip decisions (dry-run, no afplay)
set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SELF_DIR/.." && pwd)
CHIME="$ROOT/bin/claura-chime.sh"
failed=0
assert_eq() {
  local got="$1" expected="$2" name="$3"
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL $name: got '$got' expected '$expected'" >&2
    failed=$((failed + 1))
  fi
}

export CLAURA_CHIME_DRY=1

got=$(printf '%s' '{"reason":"end_turn"}' | "$CHIME" stop)
assert_eq "$got" "play" "stop chime on end_turn"

got=$(printf '%s' '{}' | "$CHIME" stop)
assert_eq "$got" "play" "stop chime when reason absent (Claude)"

got=$(printf '%s' '{"reason":"channel_closed"}' | "$CHIME" stop)
assert_eq "$got" "skip" "stop chime skipped on session teardown"

got=$(printf '%s' '{"reason":"shutdown"}' | "$CHIME" stop)
assert_eq "$got" "skip" "stop chime skipped on shutdown"

got=$(printf '%s' '{"reason":"end_turn"}' | "$CHIME" permission)
assert_eq "$got" "play" "permission chime always plays"

if (( failed > 0 )); then
  echo "$failed assertion(s) failed" >&2
  exit 1
fi
echo "chime.sh: all assertions passed"
exit 0
