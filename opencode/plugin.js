// opencode/plugin.js
//
// OpenCode adapter for Claura. OpenCode does not speak hooks.json, so this
// plugin translates OpenCode events into claura-control.sh /
// claura-chime.sh with CLAURA_HOST=opencode.
//
// Install: symlink or copy this file into ~/.config/opencode/plugins/
// and keep a Claura install that this file can find (see findClauraRoot).

import { existsSync, readdirSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOST = 'opencode'

function findClauraRoot() {
  if (process.env.CLAURA_PLUGIN_ROOT && existsSync(join(process.env.CLAURA_PLUGIN_ROOT, 'bin/claura-control.sh'))) {
    return process.env.CLAURA_PLUGIN_ROOT
  }
  const home = homedir()
  const direct = [
    join(home, '.grok/plugins/claura'),
    join(home, '.claude/plugins/claura'),
  ]
  for (const root of direct) {
    if (existsSync(join(root, 'bin/claura-control.sh'))) return root
  }
  for (const parent of [
    join(home, '.grok/installed-plugins'),
    join(home, '.claude/plugins/cache/claura-marketplace'),
    join(home, '.claude/plugins/cache'),
  ]) {
    if (!existsSync(parent)) continue
    let entries = []
    try {
      entries = readdirSync(parent, { withFileTypes: true })
    } catch {
      continue
    }
    for (const ent of entries) {
      if (!ent.isDirectory()) continue
      const root = join(parent, ent.name)
      if (existsSync(join(root, 'bin/claura-control.sh'))) return root
      // cache/claura-marketplace/claura/<ver>
      if (existsSync(join(root, 'claura'))) {
        let vers = []
        try {
          vers = readdirSync(join(root, 'claura'), { withFileTypes: true })
        } catch {
          continue
        }
        for (const ver of vers) {
          const nested = join(root, 'claura', ver.name)
          if (existsSync(join(nested, 'bin/claura-control.sh'))) return nested
        }
      }
    }
  }
  return ''
}

const ROOT = findClauraRoot()
const CONTROL = ROOT ? join(ROOT, 'bin/claura-control.sh') : ''
const CHIME = ROOT ? join(ROOT, 'bin/claura-chime.sh') : ''

function run(bin, args, payload) {
  if (!bin || !existsSync(bin)) return
  const child = spawn('/bin/bash', [bin, ...args], {
    env: {
      ...process.env,
      CLAURA_HOST: HOST,
      CLAUDE_PLUGIN_ROOT: ROOT,
      CLAURA_PLUGIN_ROOT: ROOT,
    },
    stdio: ['pipe', 'ignore', 'ignore'],
  })
  child.stdin.end(JSON.stringify(payload || {}))
  child.unref()
}

function control(cmd, sessionID, extra) {
  const sid = String(sessionID || '').replace(/[^a-zA-Z0-9-]/g, '') || `pid-${process.pid}`
  run(CONTROL, [cmd], {
    sessionId: sid,
    hookEventName: cmd,
    ...extra,
  })
}

function chime(kind) {
  run(CHIME, [kind], {})
}

export const OpenCodeAura = async () => {
  if (!CONTROL) {
    console.error('claura opencode adapter: claura-control.sh not found. Install Claura (Claude or Grok plugin) first.')
  }
  return {
    'tool.execute.before': async ({ sessionID }) => {
      control('working', sessionID)
    },
    event: async ({ event }) => {
      const props = event.properties || {}
      switch (event.type) {
        case 'session.status': {
          const status = props.status || {}
          if (status.type === 'busy' || status.type === 'retry') control('working', props.sessionID)
          if (status.type === 'idle') control('idle', props.sessionID)
          break
        }
        case 'session.idle':
          chime('stop')
          control('idle', props.sessionID)
          break
        case 'permission.asked':
          chime('permission')
          control('idle', props.sessionID)
          break
        case 'permission.replied':
          control('working', props.sessionID)
          break
        case 'session.error':
        case 'session.deleted':
          control(event.type === 'session.deleted' ? 'end' : 'idle', props.sessionID)
          break
      }
    },
  }
}

export default OpenCodeAura
