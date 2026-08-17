<p align="center">
  <img src="logo.png" alt="Claura" width="100%">
</p>

# Claura

[![validate](https://github.com/scrocchi/claura/actions/workflows/validate.yml/badge.svg)](https://github.com/scrocchi/claura/actions/workflows/validate.yml)

Ambient audio for [Claude Code](https://claude.com/claude-code) and
[Grok](https://grok.com). Plays a soundscape while the host is working and
stops the instant it goes idle — even when you press Escape mid-generation.

Each host has its own player and can use its own sound, so Claude and Grok
can run at the same time without sharing a track.

**0.1.1 ships macOS-only.** Linux and Windows are planned for 0.2.0+.

## How it works

Hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`Stop`, `StopCancelled`, `PermissionRequest`, `StopFailure`, `Notification`,
`SessionEnd`) drive a small controller that registers/unregisters each
session per host. A background player runs as long as that host has a
"working" session. Aliveness is refreshed by both hook events and a CPU
sampler watching the host process tree (`claude` or `grok`), so the audio
survives long model thinking (hooks don't fire then) but cuts within ~10s
of Escape or idle.

Grok sends camelCase hook payloads (`sessionId`) and fires `StopCancelled`
on Escape; Claude's snake_case and `Stop` path is unchanged. Unknown events
are ignored by the other host.

Two short system chimes are also wired in:

- `Glass.aiff` on a genuine `Stop` (`reason` empty or `end_turn`).
- `Pop.aiff` on `PermissionRequest` (Claude) or `Notification` /
  `permission_prompt` (Grok).

## Install

From GitHub (recommended):

```sh
claude plugin marketplace add scrocchi/claura
claude plugin install claura@claura-marketplace
```

Grok (same marketplace; trust the plugin so its hooks run):

```sh
grok plugin marketplace add scrocchi/claura
grok plugin install claura --trust
```

(Equivalent: `claude plugin marketplace add https://github.com/scrocchi/claura`.)

From a local checkout (for development):

```sh
git clone https://github.com/scrocchi/claura
claude plugin marketplace add ./claura
claude plugin install claura@claura-marketplace
# or: grok plugin marketplace add ./claura && grok plugin install claura --trust
```

OpenCode (separate runtime — it does not speak `hooks.json`):

```sh
mkdir -p ~/.config/opencode/plugins
ln -sf "$(pwd)/opencode/plugin.js" ~/.config/opencode/plugins/claura.js
# optional: pick a track for that host
# /claura:menu set sound birds opencode
```

The adapter drives the same `claura-control.sh` with `CLAURA_HOST=opencode`. It looks for an existing Claura install under `CLAURA_PLUGIN_ROOT`, `~/.grok/plugins/claura`, or the Claude plugin cache.

That's it — no `settings.json` edits. The plugin owns its own state under
`${CLAUDE_PLUGIN_DATA}` (or `${GROK_PLUGIN_DATA}`). If a Claude data dir is
already bootstrapped, Grok reuses it so sounds and volume stay shared.

### Requirements

- macOS (uses `afplay`, `stat -f`, BSD `ps`).
- `jq` on `PATH` (`brew install jq`).

## Sound

Claura ships with a bundled `birds` soundscape, used by default — no setup
needed.

To use your own audio instead, drop an `.mp3` (loopable, ~60–300s works best)
into:

```
${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claura}/sounds/<name>.mp3
```

Then point Claura at it:

```
/claura:menu set sound <name>
/claura:menu set sound <name> grok    # only the Grok player
```

(Without the `.mp3` extension.) `/claura:menu status` lists every sound it
can find under `available_sounds`, plus `host`, `hosts`, and
`sound_for_host`. The top-level `sound` key is Claude's default; Grok reads
`hosts.grok.sound` when set.

## Configure

The slash command is the supported interface:

```
/claura:menu                     # full status JSON
/claura:menu on                  # enable + unmute
/claura:menu off                 # disable + stop player
/claura:menu mute                # mute + stop player
/claura:menu set volume 60           # default / Claude
/claura:menu set volume 80 grok      # Grok only
/claura:menu set volume 40 opencode  # OpenCode only
/claura:menu set sound <name>           # Claude default (or current host)
/claura:menu set sound <name> grok      # Grok override only
/claura:menu set sound <name> opencode  # OpenCode override only
```

`status` returns one line of JSON with: `enabled`, `sound`, `volume`,
`muted`, `threshold`, `hysteresis`, `max_stale`, `available_sounds`,
`legacy_detected`, `data_dir`, `plugin_root`.

You can also run the script directly:
`${CLAUDE_PLUGIN_ROOT}/bin/claura-cli.sh status`.

## Uninstall

```sh
claude plugin uninstall claura
```

Removes the plugin and stops the active player. Your sounds under
`${CLAUDE_PLUGIN_DATA}/sounds/` and your `config.json` stay.

To reset settings without uninstalling:

```sh
rm "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claura}/config.json"
```

The bootstrap re-seeds defaults on the next session.

## Files in `${CLAUDE_PLUGIN_DATA}`

```
config.json              # enabled, sound, volume, muted, threshold, hysteresis, max_stale
sounds/*.mp3             # user-dropped sounds
state/sessions/<sid>     # one file per active session (contents = claude pid)
state/sessions/<sid>.cpu # CPU sampler sidecar (refreshed during model thinking)
state/baseline/<sid>     # CPU sampler baseline (prev pid + cputime + walltime)
state/player.pid         # PID of the running player
state/player.root        # CLAUDE_PLUGIN_ROOT the player was spawned from
state/lock.d/            # mkdir lock for the controller
.bootstrapped            # marker — bootstrap has run
.legacy-detected         # marker — prototype install detected, plugin is inert
.legacy-cleared          # marker — user resolved the legacy install
```

## Releasing

```sh
# 1. Bump `version` in both manifests by hand:
#       .claude-plugin/plugin.json
#       .claude-plugin/marketplace.json
# 2. Commit.
# 3. Create the canonical tag (validates manifest agreement):
claude plugin tag .
# 4. Push it:
git push origin "refs/tags/claura--v$(jq -r .version .claude-plugin/plugin.json)"
```

`claude plugin tag` writes a tag of the form `<plugin>--v<version>` (e.g.
`claura--v0.1.0`) after checking that `plugin.json` and the marketplace
entry agree on the version. There is intentionally no helper script in
0.1.0 — bump both manifests by hand.

## License

MIT — see [`LICENSE`](LICENSE).
