#!/usr/bin/env bash
# tests/host.sh — unit tests for host helpers in bin/_lib.sh
set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SELF_DIR/.." && pwd)
# shellcheck source=bin/_lib.sh
source "$ROOT/bin/_lib.sh"

failed=0
assert_eq() {
  local got="$1" expected="$2" name="$3"
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL $name: got '$got' expected '$expected'" >&2
    failed=$((failed + 1))
  fi
}

# --- detect host -------------------------------------------------------------
unset CLAURA_HOST GROK_PLUGIN_ROOT GROK_SESSION_ID GROK_HOOK_EVENT CODEX_HOME CODEX_THREAD_ID CODEX_SESSION_ID 2>/dev/null || true
assert_eq "$(claura_detect_host)" "claude" "detect_host default is claude"

CLAURA_HOST=grok
assert_eq "$(claura_detect_host)" "grok" "detect_host honors CLAURA_HOST"
unset CLAURA_HOST

GROK_PLUGIN_ROOT=/tmp/fake
assert_eq "$(claura_detect_host)" "grok" "detect_host grok via GROK_PLUGIN_ROOT"
unset GROK_PLUGIN_ROOT

GROK_SESSION_ID=abc
assert_eq "$(claura_detect_host)" "grok" "detect_host grok via GROK_SESSION_ID"
unset GROK_SESSION_ID

CODEX_HOME=/tmp/codex-home
assert_eq "$(claura_detect_host)" "codex" "detect_host codex via CODEX_HOME"
unset CODEX_HOME

CODEX_THREAD_ID=thread-123
assert_eq "$(claura_detect_host)" "codex" "detect_host codex via CODEX_THREAD_ID"
unset CODEX_THREAD_ID

CODEX_SESSION_ID=session-123
assert_eq "$(claura_detect_host)" "codex" "detect_host codex via CODEX_SESSION_ID"
unset CODEX_SESSION_ID

claura_find_host_pid() { printf '4242\n'; }
ps() {
  case "$2" in
    comm=) printf '/usr/local/bin/codex\n' ;;
    command=) printf '/usr/local/bin/codex\n' ;;
  esac
}
assert_eq "$(claura_detect_host)" "codex" "detect_host codex from hook ancestry"
unset -f ps claura_find_host_pid
# Restore the real helper after the isolated process-table stub.
source "$ROOT/bin/_lib.sh"

# --- sanitize host -----------------------------------------------------------
assert_eq "$(claura_sanitize_host 'grok')" "grok" "sanitize keeps grok"
assert_eq "$(claura_sanitize_host 'opencode')" "opencode" "sanitize keeps opencode"
assert_eq "$(claura_sanitize_host 'codex')" "codex" "sanitize keeps codex"
assert_eq "$(claura_sanitize_host 'GROK')" "grok" "sanitize lowercases"
assert_eq "$(claura_sanitize_host 'foo/../bar')" "foobar" "sanitize strips path chars"
assert_eq "$(claura_sanitize_host '')" "claude" "sanitize empty → claude"
assert_eq "$(claura_sanitize_host '...')" "claude" "sanitize punctuation-only → claude"

# --- json get ----------------------------------------------------------------
claude_json='{"session_id":"sid-claude","hook_event_name":"stop"}'
grok_json='{"sessionId":"sid-grok","hookEventName":"stopCancelled"}'
both_json='{"sessionId":"camel","session_id":"snake"}'
assert_eq "$(claura_json_get "$claude_json" sessionId session_id)" "sid-claude" "json snake_case"
assert_eq "$(claura_json_get "$grok_json" sessionId session_id)" "sid-grok" "json camelCase"
assert_eq "$(claura_json_get "$both_json" sessionId session_id)" "camel" "json prefers first key"
assert_eq "$(claura_json_get "$grok_json" hookEventName hook_event_name)" "stopCancelled" "json event camelCase"
assert_eq "$(claura_json_get '{}' sessionId session_id)" "" "json missing → empty"

# --- data dir: CLAURA_DATA_DIR wins -----------------------------------------
export CLAURA_DATA_DIR="/tmp/claura-explicit"
assert_eq "$(claura_data_dir)" "/tmp/claura-explicit" "data_dir explicit override"
unset CLAURA_DATA_DIR

# --- data dir: bootstrapped existing dir wins over empty GROK_PLUGIN_DATA ---
tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/claura-home.XXXXXX")
cleanup_home() { rm -rf "$tmp_home"; }
trap cleanup_home EXIT
export HOME="$tmp_home"
unset CLAUDE_PLUGIN_DATA GROK_PLUGIN_DATA CLAURA_DATA_DIR
boot="$tmp_home/.claude/plugins/data/claura-claura-marketplace"
mkdir -p "$boot/state"
echo '{}' > "$boot/config.json"
# also point Grok at a not-yet-bootstrapped path
export GROK_PLUGIN_DATA="$tmp_home/.grok/plugins/data/claura-fresh"
mkdir -p "$GROK_PLUGIN_DATA"
got=$(claura_data_dir)
# canonicalize
got=$(cd "$got" && pwd -P)
want=$(cd "$boot" && pwd -P)
assert_eq "$got" "$want" "data_dir prefers bootstrapped Claude dir over empty GROK_PLUGIN_DATA"

# --- data dir: Grok sets BOTH envs to a fresh dir; Claude bootstrapped wins --
unset _CLAURA_DATA_DIR
export CLAUDE_PLUGIN_DATA="$GROK_PLUGIN_DATA"
got=$(claura_data_dir)
got=$(cd "$got" && pwd -P)
want=$(cd "$boot" && pwd -P)
assert_eq "$got" "$want" "data_dir prefers bootstrapped Claude when Grok aliases both envs to a fresh dir"
unset CLAUDE_PLUGIN_DATA

# --- data dir: GROK_PLUGIN_DATA when nothing bootstrapped -------------------
rm -rf "$tmp_home/.claude"
unset _CLAURA_DATA_DIR
got=$(claura_data_dir)
got=$(cd "$got" && pwd -P)
want=$(cd "$GROK_PLUGIN_DATA" && pwd -P)
assert_eq "$got" "$want" "data_dir uses GROK_PLUGIN_DATA when nothing bootstrapped"
unset GROK_PLUGIN_DATA

# --- cfg host sound ----------------------------------------------------------
cfg_dir=$(mktemp -d "${TMPDIR:-/tmp}/claura-cfg.XXXXXX")
export CLAURA_DATA_DIR="$cfg_dir"
unset _CLAURA_DATA_DIR
cat > "$cfg_dir/config.json" <<'EOF'
{
  "sound": "rain-window-01",
  "hosts": { "grok": { "sound": "grok" } }
}
EOF
assert_eq "$(claura_cfg_host_sound claude)" "rain-window-01" "host sound claude uses default"
assert_eq "$(claura_cfg_host_sound grok)" "grok" "host sound grok uses override"
assert_eq "$(claura_cfg_host_sound opencode)" "rain-window-01" "host sound unknown falls back to default"
assert_eq "$(claura_cfg_host_sound codex)" "rain-window-01" "host sound codex falls back to default"

# --- cfg host volume ---------------------------------------------------------
cat > "$cfg_dir/config.json" <<'EOF'
{
  "sound": "rain-window-01",
  "volume": 30,
  "hosts": { "grok": { "sound": "grok", "volume": 80 } }
}
EOF
assert_eq "$(claura_cfg_host_volume claude)" "30" "host volume claude uses default"
assert_eq "$(claura_cfg_host_volume grok)" "80" "host volume grok uses override"

# --- paths namespaced --------------------------------------------------------
assert_eq "$(claura_sessions_dir grok)" "$cfg_dir/state/sessions/grok" "sessions dir namespaced"
assert_eq "$(claura_player_pid_file grok)" "$cfg_dir/state/player.grok.pid" "player pid namespaced"
assert_eq "$(claura_player_pid_file claude)" "$cfg_dir/state/player.claude.pid" "player pid claude namespaced"
assert_eq "$(claura_player_pid_file codex)" "$cfg_dir/state/player.codex.pid" "player pid codex namespaced"

# --- find_host_pid -----------------------------------------------------------
# pid 1 has no host ancestor. Our own tree may include grok/claude (this
# test often runs inside a Grok session) — if it does, the comm must match.
got=$(claura_find_host_pid 1)
assert_eq "$got" "" "find_host_pid of pid 1 is empty"
got=$(claura_find_host_pid $$)
if [[ -n "$got" ]]; then
  base=$(ps -o comm= -p "$got" 2>/dev/null); base=${base##*/}
  case "$base" in
    claude|grok|grok-*|codex) ;;
    *)
      echo "FAIL find_host_pid $$ matched pid $got comm='$base'" >&2
      failed=$((failed + 1))
      ;;
  esac
fi

got=$(claura_pgrep_host grok)
if [[ -n "$got" ]]; then
  base=$(ps -o comm= -p "$got" 2>/dev/null); base=${base##*/}
  case "$base" in
    grok|grok-*) ;;
    *)
      echo "FAIL pgrep_host grok matched pid $got comm='$base'" >&2
      failed=$((failed + 1))
      ;;
  esac
fi
if (( failed > 0 )); then
  echo "$failed assertion(s) failed" >&2
  exit 1
fi
echo "host.sh: all assertions passed"
exit 0
