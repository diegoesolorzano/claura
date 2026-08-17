#!/usr/bin/env bash
# bin/_lib.sh
#
# Shared helpers sourced by every Claura script. Do not execute directly.
# Conventions:
#   - Caller scripts set their own `set -u` / `set -e`. We don't.
#   - All env vars referenced via ${VAR:-default} so we're safe under -u.
#   - macOS-only in 0.1.0; os_detect bails cleanly on other OSes.

# --- OS gate -----------------------------------------------------------------
# 0.1.0 is macOS-only. On any other OS we exit the CALLING script with code 0
# so hooks don't appear as failures. Stderr message is the only user-facing
# breadcrumb (visible via `claude --debug`).
os_detect() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'darwin\n' ;;
    *)
      echo "Claura 0.1.0 is macOS-only; Linux/Windows support coming in 0.2.0" >&2
      exit 0
      ;;
  esac
}

# --- host --------------------------------------------------------------------
# Known hosts: claude | grok. CLAURA_HOST overrides detection so another
# runtime (OpenCode) can drive the same controller without spoofing env.
claura_sanitize_host() {
  local h
  h=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
  if [[ -z "$h" ]]; then
    printf 'claude\n'
  else
    printf '%s\n' "$h"
  fi
}

claura_detect_host() {
  if [[ -n "${CLAURA_HOST:-}" ]]; then
    claura_sanitize_host "$CLAURA_HOST"
    return 0
  fi
  if [[ -n "${GROK_PLUGIN_ROOT:-}" || -n "${GROK_PLUGIN_DATA:-}" \
     || -n "${GROK_SESSION_ID:-}" || -n "${GROK_HOOK_EVENT:-}" ]]; then
    printf 'grok\n'
    return 0
  fi
  printf 'claude\n'
}

# First non-empty top-level key from a JSON object. Used to accept both
# Claude's snake_case hook payloads and Grok's camelCase.
claura_json_get() {
  local json="${1:-}" k val
  shift || true
  [[ -z "$json" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  for k in "$@"; do
    [[ -z "$k" ]] && continue
    val=$(printf '%s' "$json" | jq -r --arg k "$k" '.[$k] // empty' 2>/dev/null || true)
    if [[ -n "$val" && "$val" != "null" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  done
}

# Walk up from PID (default: $PPID) looking for the host executable.
# Matches `claude`, `grok`, and `grok-*` (versioned Grok binaries).
claura_find_host_pid() {
  local pid="${1:-$PPID}" base cmdline
  for _ in $(seq 1 10); do
    [[ -z "$pid" || "$pid" -le 1 ]] && break
    base=$(ps -o comm= -p "$pid" 2>/dev/null); base=${base##*/}
    case "$base" in
      claude|grok|grok-*) printf '%s\n' "$pid"; return 0 ;;
    esac
    if [[ "$base" == node* ]]; then
      cmdline=$(ps -o command= -p "$pid" 2>/dev/null)
      if [[ "$cmdline" == *claude* || "$cmdline" == *grok* ]]; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

# --- paths -------------------------------------------------------------------
# Resolution order:
#   1. $CLAURA_DATA_DIR
#   2. a bootstrapped dir under ~/.claude/plugins/data/claura* or
#      ~/.grok/plugins/data/claura* (config.json or state/) — so Grok reuses
#      the Claude install's sounds/config instead of starting empty
#   3. $GROK_PLUGIN_DATA / $CLAUDE_PLUGIN_DATA
#   4. ~/.claude/plugins/data/claura
claura_discover_data_dirs() {
  local base d resolved found="" restore
  restore=$(shopt -p nullglob 2>/dev/null || true)
  shopt -s nullglob
  for base in "$HOME/.claude/plugins/data" "$HOME/.grok/plugins/data"; do
    for d in "$base"/claura "$base"/claura-*; do
      [[ -d "$d" ]] || continue
      [[ -f "$d/config.json" || -d "$d/state" ]] || continue
      resolved=$(cd "$d" 2>/dev/null && pwd -P) || continue
      [[ -n "$resolved" ]] || continue
      printf '%s\n' "$found" | grep -qxF -- "$resolved" && continue
      found="${found:+$found
}$resolved"
    done
  done
  [[ -n "$restore" ]] && eval "$restore"
  printf '%s' "$found"
}

claura_data_dir() {
  local found count first candidate res
  if [[ -n "${CLAURA_DATA_DIR:-}" ]]; then
    printf '%s\n' "$CLAURA_DATA_DIR"
    return 0
  fi
  if [[ -n "${_CLAURA_DATA_DIR:-}" ]]; then
    printf '%s\n' "$_CLAURA_DATA_DIR"
    return 0
  fi

  found=$(claura_discover_data_dirs)
  count=0
  [[ -n "$found" ]] && count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')

  if (( count == 1 )); then
    _CLAURA_DATA_DIR="$found"
  elif (( count > 1 )); then
    first=$(printf '%s\n' "$found" | head -1)
    for candidate in "${GROK_PLUGIN_DATA:-}" "${CLAUDE_PLUGIN_DATA:-}"; do
      [[ -z "$candidate" ]] && continue
      res=$(cd "$candidate" 2>/dev/null && pwd -P) || continue
      if printf '%s\n' "$found" | grep -qxF -- "$res"; then
        first="$res"
        break
      fi
    done
    _CLAURA_DATA_DIR="$first"
  elif [[ -n "${GROK_PLUGIN_DATA:-}" ]]; then
    _CLAURA_DATA_DIR="$GROK_PLUGIN_DATA"
  elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
    _CLAURA_DATA_DIR="$CLAUDE_PLUGIN_DATA"
  else
    _CLAURA_DATA_DIR="$HOME/.claude/plugins/data/claura"
  fi
  printf '%s\n' "$_CLAURA_DATA_DIR"
}

claura_root_dir() {
  printf '%s\n' "${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
}

claura_sessions_dir() {
  printf '%s/state/sessions/%s\n' "$(claura_data_dir)" "$(claura_sanitize_host "${1:-}")"
}

claura_baseline_dir() {
  printf '%s/state/baseline/%s\n' "$(claura_data_dir)" "$(claura_sanitize_host "${1:-}")"
}

claura_player_pid_file() {
  printf '%s/state/player.%s.pid\n' "$(claura_data_dir)" "$(claura_sanitize_host "${1:-}")"
}

claura_player_root_file() {
  printf '%s/state/player.%s.root\n' "$(claura_data_dir)" "$(claura_sanitize_host "${1:-}")"
}

# --- config get --------------------------------------------------------------
# Usage: claura_cfg_get KEY DEFAULT
# Prints DEFAULT if config.json is missing, jq is missing, the key is absent,
# or jq yields "null". Always single-line stdout.
claura_cfg_get() {
  local key="$1" def="${2-}" cfg val
  cfg="$(claura_data_dir)/config.json"
  if [[ ! -f "$cfg" ]] || ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$def"
    return 0
  fi
  val=$(jq -r --arg k "$key" '.[$k] // empty' "$cfg" 2>/dev/null || true)
  if [[ -z "$val" || "$val" == "null" ]]; then
    val="$def"
  fi
  printf '%s\n' "$val"
}

# hosts.$host.sound if set, else top-level sound, else "birds".
claura_cfg_host_sound() {
  local host def cfg val
  host=$(claura_sanitize_host "${1:-}")
  def=$(claura_cfg_get sound birds)
  cfg="$(claura_data_dir)/config.json"
  if [[ ! -f "$cfg" ]] || ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$def"
    return 0
  fi
  val=$(jq -r --arg h "$host" '.hosts[$h].sound // empty' "$cfg" 2>/dev/null || true)
  if [[ -z "$val" || "$val" == "null" ]]; then
    val="$def"
  fi
  printf '%s\n' "$val"
}

# --- sound resolution --------------------------------------------------------
# Resolution order, in this priority:
#   1. ${CLAUDE_PLUGIN_DATA}/sounds/<name>.mp3   (user-dropped)
#   2. ${CLAUDE_PLUGIN_ROOT}/audio/<name>.mp3    (bundled)
# Falls back to "birds" by the same lookup if NAME does not resolve.
# Prints the absolute path on success; returns non-zero with no output if
# nothing is found.
claura_resolve_sound() {
  local name="${1:-birds}" data root n file
  data=$(claura_data_dir)
  root=$(claura_root_dir)
  for n in "$name" "birds"; do
    [[ -z "$n" ]] && continue
    for file in "$data/sounds/$n.mp3" "$root/audio/$n.mp3"; do
      if [[ -f "$file" ]]; then
        printf '%s\n' "$file"
        return 0
      fi
    done
  done
  return 1
}

# --- volume conversion -------------------------------------------------------
# Map a 0..100 percentage to afplay's 0.0..1.0 scale, clamped.
claura_vol_for_afplay() {
  awk -v p="${1:-100}" '
    BEGIN {
      p = p + 0
      if (p < 0)   p = 0
      if (p > 100) p = 100
      printf "%.3f", p / 100
    }
  '
}

# --- one-shot playback -------------------------------------------------------
# Plays FILE once at PCT volume. Caller is responsible for backgrounding and
# tracking the resulting PID; we run afplay in the foreground.
claura_play_loop() {
  local file="$1" pct="${2:-100}" vol
  vol=$(claura_vol_for_afplay "$pct")
  exec afplay -v "$vol" "$file"
}

# --- stop the running player -------------------------------------------------
# Idempotent. With a host argument, stops that host's player. With none,
# stops every player.*.pid plus the legacy player.pid.
claura_stop_one_pidfile() {
  local pidfile="$1" pid _
  [[ -f "$pidfile" ]] || return 0
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$pidfile"
}

claura_stop_player() {
  local host="${1:-}" state f restore
  state="$(claura_data_dir)/state"
  if [[ -n "$host" ]]; then
    claura_stop_one_pidfile "$(claura_player_pid_file "$host")"
    rm -f "$(claura_player_root_file "$host")"
    return 0
  fi
  claura_stop_one_pidfile "$state/player.pid"
  restore=$(shopt -p nullglob 2>/dev/null || true)
  shopt -s nullglob
  for f in "$state"/player.*.pid; do
    claura_stop_one_pidfile "$f"
    rm -f "${f%.pid}.root"
  done
  [[ -n "$restore" ]] && eval "$restore"
}

# --- stat/date wrappers ------------------------------------------------------
# Single-branch wrappers in 0.1.0 (darwin only). 0.2.0 will add Linux branches
# here without callers needing to change.
stat_mtime() {
  stat -f %m "$1" 2>/dev/null || echo 0
}

stat_size() {
  stat -f %z "$1" 2>/dev/null || echo 0
}

date_epoch() {
  date +%s
}
