#!/usr/bin/env bash
# tests/opencode-plugin.sh — the OpenCode adapter must stay loadable by OpenCode 2
# (default export with id + setup) and map v2 events onto claura-control/chime.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN="$SELF_DIR/../opencode/plugin.js"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/bin"
for script in claura-control.sh claura-chime.sh; do
  cat > "$TMP/root/bin/$script" <<EOF
#!/usr/bin/env bash
printf '%s %s host=%s sid=%s\n' "$script" "\$1" "\$CLAURA_HOST" "\$(cat | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)" >> "$TMP/calls.log"
EOF
done

CLAURA_PLUGIN_ROOT="$TMP/root" ORCA_PANE_KEY= CLAURA_HOST=opencode-test \
  node --input-type=module -e "
import plugin from '$PLUGIN'
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }

if (plugin.id !== 'claura') fail('default export needs id claura')
if (typeof plugin.setup !== 'function') fail('v2 needs setup()')
if (typeof plugin.server !== 'function') fail('v1 object form needs server()')

const events = [
  { type: 'session.execution.started', data: { sessionID: 'ses_a' } },
  { type: 'session.execution.succeeded', data: { sessionID: 'ses_a' } },
  { type: 'permission.asked', data: { sessionID: 'ses_b' } },
  { type: 'permission.replied', data: { sessionID: 'ses_b' } },
  { type: 'session.execution.failed', data: { sessionID: 'ses_c' } },
  { type: 'session.deleted', data: { sessionID: 'ses_d' } },
]
let toolHandler
const ctx = {
  tool: { hook: async (name, fn) => { if (name === 'execute.before') toolHandler = fn; return { dispose: async () => {} } } },
  event: { subscribe: async function* () { for (const e of events) yield e } },
}
const cleanup = await plugin.setup(ctx)
toolHandler({ sessionID: 'ses_t' })
await new Promise((r) => setTimeout(r, 600))
await cleanup()
"

# control() strips non [a-zA-Z0-9-] from session ids, so ses_a arrives as sesa.
expect() {
  grep -qF "$1" "$TMP/calls.log" || { echo "FAIL: missing call: $1"; cat "$TMP/calls.log"; exit 1; }
}
expect 'claura-control.sh working host=opencode-test sid=sest'
expect 'claura-control.sh working host=opencode-test sid=sesa'
expect 'claura-chime.sh stop'
expect 'claura-control.sh idle host=opencode-test sid=sesa'
expect 'claura-chime.sh permission'
expect 'claura-control.sh working host=opencode-test sid=sesb'
expect 'claura-control.sh idle host=opencode-test sid=sesc'
expect 'claura-control.sh end host=opencode-test sid=sesd'
echo "opencode-plugin.sh: all assertions passed"
