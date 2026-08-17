#!/usr/bin/env bash
# tests/cli.sh — set sound [host] writes the right config key
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

tmp=$(mktemp -d "${TMPDIR:-/tmp}/claura-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export CLAURA_DATA_DIR="$tmp"
unset CLAURA_HOST GROK_PLUGIN_ROOT GROK_PLUGIN_DATA GROK_SESSION_ID GROK_HOOK_EVENT
mkdir -p "$tmp/sounds"
# a dummy user sound so "grok" is an allowed name
: > "$tmp/sounds/grok.mp3"
# CLI seeds config via bootstrap; give it a writable dir and jq
cat > "$tmp/config.json" <<'EOF'
{"enabled":true,"sound":"birds","volume":30,"muted":false}
EOF

out=$(CLAURA_HOST=claude "$ROOT/bin/claura-cli.sh" set sound birds)
got=$(jq -r .sound "$tmp/config.json")
assert_eq "$got" "birds" "claude set sound writes top-level sound"

out=$(CLAURA_HOST=grok "$ROOT/bin/claura-cli.sh" set sound grok)
got=$(jq -r '.hosts.grok.sound' "$tmp/config.json")
assert_eq "$got" "grok" "grok set sound writes hosts.grok.sound"
got=$(jq -r .sound "$tmp/config.json")
assert_eq "$got" "birds" "grok set sound does not clobber default"

out=$(CLAURA_HOST=claude "$ROOT/bin/claura-cli.sh" set sound grok grok)
got=$(jq -r '.hosts.grok.sound' "$tmp/config.json")
assert_eq "$got" "grok" "explicit host arg wins over CLAURA_HOST"

out=$(CLAURA_HOST=grok "$ROOT/bin/claura-cli.sh" status)
got=$(printf '%s' "$out" | jq -r .host)
assert_eq "$got" "grok" "status reports host=grok"
got=$(printf '%s' "$out" | jq -r .sound_for_host)
assert_eq "$got" "grok" "status sound_for_host is grok override"

if (( failed > 0 )); then
  echo "$failed assertion(s) failed" >&2
  exit 1
fi
echo "cli.sh: all assertions passed"
exit 0
