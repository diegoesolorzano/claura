#!/usr/bin/env bash
# tests/control.sh — stale idle / subagent events must not reap a live session
set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SELF_DIR/.." && pwd)
failed=0
assert_eq() {
  local got="$1" expected="$2" name="$3"
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL $name: got '$got' expected '$expected'" >&2
    failed=$((failed + 1))
  fi
}
assert_file() {
  local path="$1" name="$2"
  if [[ ! -f "$path" ]]; then
    echo "FAIL $name: missing $path" >&2
    failed=$((failed + 1))
  fi
}
assert_no_file() {
  local path="$1" name="$2"
  if [[ -f "$path" ]]; then
    echo "FAIL $name: unexpected $path" >&2
    failed=$((failed + 1))
  fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/claura-ctl.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export CLAURA_DATA_DIR="$tmp"
export CLAURA_HOST=grok
unset GROK_PLUGIN_ROOT GROK_PLUGIN_DATA GROK_SESSION_ID GROK_HOOK_EVENT
mkdir -p "$tmp"
cat > "$tmp/config.json" <<'EOF'
{"enabled":false,"sound":"birds","volume":30,"muted":false}
EOF
# enabled=false → control records sessions but does not spawn afplay

sid="sess-1"
sessions="$tmp/state/sessions/grok"
ctl() { "$ROOT/bin/claura-control.sh" "$1"; }

printf '%s' '{"sessionId":"'"$sid"'","promptId":"p1"}' | ctl working
assert_file "$sessions/$sid" "working creates session"
assert_file "$sessions/$sid.prompt" "working records promptId"

# Stale StopCancelled for p1 arriving after a new turn p2 must not reap.
printf '%s' '{"sessionId":"'"$sid"'","promptId":"p2"}' | ctl working
printf '%s' '{"sessionId":"'"$sid"'","promptId":"p1"}' | ctl idle
assert_file "$sessions/$sid" "stale idle does not delete newer turn"

# Matching idle on Grok does NOT clear: audio is process-scoped.
printf '%s' '{"sessionId":"'"$sid"'","promptId":"p2"}' | ctl idle
assert_file "$sessions/$sid" "grok idle keeps session while grok process lives"

# SessionEnd (`end`) still tears it down.
printf '%s' '{"sessionId":"'"$sid"'","promptId":"p2"}' | ctl end
assert_no_file "$sessions/$sid" "grok end deletes session"

# Subagent events are ignored entirely.
sid2="sess-2"
printf '%s' '{"sessionId":"'"$sid2"'","promptId":"p3","subagentType":"explore"}' | ctl working
assert_no_file "$sessions/$sid2" "subagent working is ignored"

printf '%s' '{"sessionId":"'"$sid2"'","promptId":"p4"}' | ctl working
printf '%s' '{"sessionId":"'"$sid2"'","promptId":"p4","subagentType":"explore"}' | ctl idle
assert_file "$sessions/$sid2" "subagent idle does not reap parent"

# Continuation Stop (stopHookActive) is not idle.
printf '%s' '{"sessionId":"'"$sid2"'","promptId":"p4","stopHookActive":true}' | ctl idle
assert_file "$sessions/$sid2" "stopHookActive idle is ignored"

if (( failed > 0 )); then
  echo "$failed assertion(s) failed" >&2
  exit 1
fi
echo "control.sh: all assertions passed"
exit 0
