#!/usr/bin/env bash
# bin/claura-control.sh
#
# Hook dispatcher. Wired to UserPromptSubmit/PreToolUse/PostToolUse/Stop/
# PermissionRequest/StopFailure/Notification/SessionEnd. Invoked with one of:
#   working | idle | end
# plus the hook payload on stdin.
#
# Responsibilities:
#   - OS gate; lazy bootstrap on fresh installs.
#   - Honor inert-on-legacy: stay silent if the standalone-prototype install
#     is still wired in the user's settings.json.
#   - Root-mismatch killswitch: if the player was spawned from a different
#     plugin root (i.e. `claude plugin update` swapped paths), kill it so the
#     reconcile step respawns it from the current root.
#   - Register/unregister this session under an mkdir lock.
#   - Reconcile: spawn player if any session is active AND enabled AND !muted;
#     kill player if none active OR disabled OR muted.
#
# All state mutations are serialized with an mkdir lock (macOS has no flock).

set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/_lib.sh
source "$SELF_DIR/_lib.sh"

os_detect >/dev/null

DATA_DIR=$(claura_data_dir)
STATE_DIR="$DATA_DIR/state"
HOST=$(claura_detect_host)
SESSIONS_DIR=$(claura_sessions_dir "$HOST")
BASELINE_DIR=$(claura_baseline_dir "$HOST")
PLAYER_PID_FILE=$(claura_player_pid_file "$HOST")
PLAYER_ROOT_FILE=$(claura_player_root_file "$HOST")
LOCK_DIR="$STATE_DIR/lock.d"
BOOTSTRAPPED="$DATA_DIR/.bootstrapped"
LEGACY_DETECTED="$DATA_DIR/.legacy-detected"
LEGACY_CLEARED="$DATA_DIR/.legacy-cleared"
PLAYER="$SELF_DIR/claura-player.sh"

LOCK_TIMEOUT_SECS=5
# Controller-side staleness ceiling. Fine-grained HYSTERESIS lives in the
# player (with the CPU sampler). Matches the prototype's value.
MAX_STALE=75
DEBUG="${CLAURA_DEBUG:-${CLAUDE_AUDIO_DEBUG:-0}}"

# --- lazy bootstrap on first hook --------------------------------------------
# Covers the "installed mid-session" case where SessionStart already fired
# before the plugin existed. Run as a subprocess with /dev/null stdin so it
# does not consume the hook payload meant for us.
if [[ ! -f "$BOOTSTRAPPED" ]]; then
  "$SELF_DIR/claura-bootstrap.sh" </dev/null >/dev/null 2>&1 || true
fi

# --- inert-on-legacy ---------------------------------------------------------
# If the standalone prototype is still wired in the user's settings.json,
# stay silent until they touch .legacy-cleared. Touching nothing here keeps
# the plugin from corrupting state that the prototype owns.
if [[ -f "$LEGACY_DETECTED" && ! -f "$LEGACY_CLEARED" ]]; then
  exit 0
fi

mkdir -p "$SESSIONS_DIR" "$BASELINE_DIR"
cmd="${1:-}"
[[ -z "$cmd" ]] && exit 0

# --- session_id from stdin JSON ---------------------------------------------
# Claude sends snake_case; Grok sends camelCase. First non-empty wins.
input=""
[[ ! -t 0 ]] && input=$(cat 2>/dev/null || true)
session_id=$(claura_json_get "$input" sessionId session_id)
hook_evt=$(claura_json_get "$input" hookEventName hook_event_name)
prompt_id=$(claura_json_get "$input" promptId prompt_id)
subagent=$(claura_json_get "$input" subagentType subagent_type)
stop_hook_active=$(claura_json_get "$input" stopHookActive stop_hook_active)
[[ -z "$session_id" ]] && session_id="pid-$PPID"
session_id=$(printf '%s' "$session_id" | tr -cd 'a-zA-Z0-9-')
prompt_id=$(printf '%s' "$prompt_id" | tr -cd 'a-zA-Z0-9-')

# A subagent's stop/end is not the host session's. Ignore it so a child's
# SessionEnd cannot reap the parent's working file.
if [[ -n "$subagent" ]]; then
  exit 0
fi

# Host executable (claude | grok | grok-*). Empty → timestamp staleness.
host_pid=$(claura_resolve_host_pid)

if [[ "$DEBUG" == "1" ]]; then
  echo "$(date '+%H:%M:%S') cmd=$cmd host=$HOST evt=${hook_evt:-?} sid=${session_id:0:8} hpid=$host_pid" \
    >> "$STATE_DIR/events.log" 2>/dev/null || true
fi

# --- acquire lock (mkdir; steal if the owner PID is dead) -------------------
acquired=false
deadline=$(( $(date_epoch) + LOCK_TIMEOUT_SECS ))
while (( $(date_epoch) < deadline )); do
  if mkdir "$LOCK_DIR" 2>/dev/null; then acquired=true; break; fi
  if [[ -f "$LOCK_DIR/owner" ]]; then
    owner=$(cat "$LOCK_DIR/owner" 2>/dev/null || echo "")
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$LOCK_DIR"; continue
    fi
  fi
  sleep 0.05
done
[[ "$acquired" == true ]] || exit 0
echo "$$" > "$LOCK_DIR/owner"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- promote pre-0.1.1 state (claude only) ---------------------------------
# Loose sessions/<sid> and player.pid belong to Claude. Move them into the
# namespaced layout so the new globs see them and the old player.pid is not
# left running beside player.claude.pid.
if [[ "$HOST" == "claude" ]]; then
  legacy_sessions="$STATE_DIR/sessions"
  for f in "$legacy_sessions"/*; do
    [[ -f "$f" ]] || continue
    mv "$f" "$SESSIONS_DIR/$(basename "$f")"
  done
  if [[ -f "$STATE_DIR/player.pid" && ! -f "$PLAYER_PID_FILE" ]]; then
    mv "$STATE_DIR/player.pid" "$PLAYER_PID_FILE"
  fi
  if [[ -f "$STATE_DIR/player.root" && ! -f "$PLAYER_ROOT_FILE" ]]; then
    mv "$STATE_DIR/player.root" "$PLAYER_ROOT_FILE"
  fi
fi

# --- root-mismatch killswitch ----------------------------------------------
# If a player is running but was spawned from a different ${CLAUDE_PLUGIN_ROOT}
# (e.g. `claude plugin update` swapped the install path), kill it so the
# reconcile step below respawns it from the current root.
CURRENT_ROOT=$(claura_root_dir)
if [[ -f "$PLAYER_PID_FILE" && -f "$PLAYER_ROOT_FILE" && -n "$CURRENT_ROOT" ]]; then
  recorded_root=$(cat "$PLAYER_ROOT_FILE" 2>/dev/null || echo "")
  if [[ -n "$recorded_root" && "$recorded_root" != "$CURRENT_ROOT" ]]; then
    stale_pid=$(cat "$PLAYER_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
      kill "$stale_pid" 2>/dev/null || true
    fi
    rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
  fi
fi

# --- apply event ------------------------------------------------------------
# On idle/end we remove the .cpu sidecar and any baseline state under the
# same lock. The watcher in the player writes the sidecar WITHOUT the lock,
# so the controller must remove main + sidecar atomically to prevent a stray
# sidecar `touch` right after rm from creating a ghost session.
case "$cmd" in
  working)
    echo "$host_pid" > "$SESSIONS_DIR/$session_id"
    if [[ -n "$prompt_id" ]]; then
      printf '%s\n' "$prompt_id" > "$SESSIONS_DIR/$session_id.prompt"
    fi
    ;;
  idle|end)
    # Grok's Stop is a gate: a continuation fire (stopHookActive) is not idle.
    # A cancelled turn's report can arrive after the next UserPromptSubmit —
    # ignore an idle whose promptId is older than the one we recorded.
    skip_idle=false
    if [[ "$stop_hook_active" == "true" ]]; then
      skip_idle=true
    fi
    if [[ -n "$prompt_id" && -f "$SESSIONS_DIR/$session_id.prompt" ]]; then
      stored_prompt=$(cat "$SESSIONS_DIR/$session_id.prompt" 2>/dev/null || true)
      if [[ -n "$stored_prompt" && "$stored_prompt" != "$prompt_id" ]]; then
        skip_idle=true
      fi
    fi
    # Grok audio is process-scoped: Stop between turns must not kill the
    # player while `grok` is still running. SessionEnd (`end`) still stops.
    if [[ "$cmd" == "idle" && "$HOST" == "grok" ]]; then
      if [[ -n "$host_pid" ]] || claura_pgrep_host grok >/dev/null; then
        skip_idle=true
      fi
    fi
    if [[ "$skip_idle" != true ]]; then
      rm -f "$SESSIONS_DIR/$session_id" \
            "$SESSIONS_DIR/$session_id.cpu" \
            "$SESSIONS_DIR/$session_id.prompt" \
            "$BASELINE_DIR/$session_id" \
            "$BASELINE_DIR/$session_id.degraded"
    fi
    ;;
  *) exit 0 ;;
esac

# --- count live sessions ----------------------------------------------------
# Controller-side count uses MAX_STALE (the degradation floor); fine-grained
# HYSTERESIS lives in the player. Skip .cpu sidecars (metadata, not sessions).
now=$(date_epoch)
active=0
shopt -s nullglob
for f in "$SESSIONS_DIR"/*; do
  [[ -d "$f" ]] && continue
  [[ "$f" == *.cpu || "$f" == *.prompt ]] && continue
  pid=$(cat "$f" 2>/dev/null)
  mtime=$(stat_mtime "$f")
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    rebound=$(claura_pgrep_host "$HOST")
    if [[ -n "$rebound" ]]; then
      printf '%s\n' "$rebound" > "$f"
      pid="$rebound"
    else
      rm -f "$f" "$f.cpu" "$f.prompt" "$BASELINE_DIR/$(basename "$f")" "$BASELINE_DIR/$(basename "$f").degraded"
      continue
    fi
  fi
  if (( now - mtime >= MAX_STALE )); then
    rm -f "$f" "$f.cpu" "$f.prompt" "$BASELINE_DIR/$(basename "$f")" "$BASELINE_DIR/$(basename "$f").degraded"
    continue
  fi
  active=$((active+1))
done

# --- is the player running? -------------------------------------------------
player_alive=false
player_pid=""
if [[ -f "$PLAYER_PID_FILE" ]]; then
  player_pid=$(cat "$PLAYER_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$player_pid" ]] && kill -0 "$player_pid" 2>/dev/null; then
    player_alive=true
  else
    rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
  fi
fi

# --- read enabled/muted from config (defaults: enabled=true, muted=false) ---
enabled=$(claura_cfg_get enabled true)
muted=$(claura_cfg_get muted false)
playable=true
if [[ "$enabled" != "true" ]] || [[ "$muted" == "true" ]]; then
  playable=false
fi

# --- reconcile --------------------------------------------------------------
# Active session + nothing playing + audio allowed → spawn.
# Otherwise (no active session OR audio disabled) and a player is running →
# kill it. We keep session files around when audio is just muted/disabled so
# re-enabling re-engages from the same state on the next hook tick.
if (( active > 0 )) && [[ "$player_alive" == false ]] && [[ "$playable" == true ]]; then
  CLAURA_HOST="$HOST" /usr/bin/env bash "$PLAYER" </dev/null >/dev/null 2>&1 &
  echo $! > "$PLAYER_PID_FILE"
  if [[ -n "$CURRENT_ROOT" ]]; then
    echo "$CURRENT_ROOT" > "$PLAYER_ROOT_FILE"
  fi
elif [[ "$player_alive" == true ]] && { (( active == 0 )) || [[ "$playable" == false ]]; }; then
  kill "$player_pid" 2>/dev/null || true
  rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
fi

exit 0
