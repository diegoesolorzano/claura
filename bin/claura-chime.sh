#!/usr/bin/env bash
# bin/claura-chime.sh
#
# One-shot system chimes. Wired from hooks.json.
#   stop        — Glass.aiff on a genuine turn end. Grok also fires Stop on
#                 session teardown (reason=channel_closed|shutdown); skip those.
#                 Claude omits `reason`; treat missing as play.
#   permission  — Pop.aiff; always plays.
#
# CLAURA_CHIME_DRY=1 prints play|skip and exits (tests).
set -u

kind="${1:-stop}"
input=""
[[ ! -t 0 ]] && input=$(cat 2>/dev/null || true)

reason=""
if [[ -n "$input" ]] && command -v jq >/dev/null 2>&1; then
  reason=$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null || true)
fi

should_play=1
case "$kind" in
  stop)
    if [[ -n "$reason" && "$reason" != "end_turn" ]]; then
      should_play=0
    fi
    sound=/System/Library/Sounds/Glass.aiff
    ;;
  permission)
    sound=/System/Library/Sounds/Pop.aiff
    ;;
  *)
    should_play=0
    sound=""
    ;;
esac

if [[ "${CLAURA_CHIME_DRY:-0}" == "1" ]]; then
  if [[ "$should_play" == "1" ]]; then
    printf 'play\n'
  else
    printf 'skip\n'
  fi
  exit 0
fi

[[ "$should_play" == "1" && -n "$sound" ]] || exit 0
exec /usr/bin/afplay "$sound"
