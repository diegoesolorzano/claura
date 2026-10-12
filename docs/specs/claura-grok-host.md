# Feature: Claura en Grok

**Feature ID:** claura-grok-host
**Repo:** claura
**Issue:** none
**Upstream:** none
**Date:** 2026-08-17
**Status:** InReview

**Tier:** standard
**Modifiers:** security-review

## Problem Statement

Claura solo reconoce Claude Code. En Grok no está instalado y, si se instalara tal cual, no identificaría la sesión (JSON camelCase), no seguiría el PID de `grok` ni cortaría en Escape (`StopCancelled`). El soundscape debe identificar el host: Claude usa Claura nativo; OpenCode usa un puerto local nuestro (`opencode-aura.js`) porque su API no es hooks.json. Grok sí habla el protocolo de Claura, así que entra al plugin, no a un puerto aparte.

## Requirements

- [ ] FR-1: Un plugin dual-host. Claude no cambia de comportamiento.
- [ ] FR-2: Audio mientras Grok trabaja (prompt, tools, thinking largo).
- [ ] FR-3: Corta en fin de turno, Escape/Ctrl+C, error de API, permiso e idle.
- [ ] FR-4: Un data dir compartido (config + `sounds/`). Players aislados por host.
- [ ] FR-5: Sonido por host. Default = `sound`. Override en `hosts.<name>.sound`.
- [ ] FR-6: Grok usa el mp3 del usuario, copiado a `sounds/` (no bundled).
- [ ] FR-7: `/claura:menu` lee/escribe el sonido del host actual; permite `set sound NAME [host]`.
- [ ] FR-8: Chimes: `Glass` al terminar limpio, `Pop` al pedir permiso.
- [ ] FR-9: PR a `scrocchi/claura` con el motor dual-host. Sin el mp3 personal.

## Acceptance Criteria

- **Given** plugin trusted en Grok, **When** envío un prompt, **Then** suena el soundscape de Grok, no el de Claude.
- **Given** Claude y Grok trabajando a la vez, **When** ambos están busy, **Then** cada host tiene su propio `afplay` y su propio sonido.
- **Given** audio de Grok sonando, **When** pulso Escape, **Then** corta en ≤ ~10 s.
- **Given** thinking largo sin tools, **When** el CPU de `grok` sigue alto, **Then** el audio no se corta.
- **Given** `config.json` actual (`sound=rain-window-01`, `volume=30`), **When** arranca Grok, **Then** Claude sigue usando esa pista; Grok usa `hosts.grok.sound`.
- **Given** una sesión solo Claude, **When** el soporte Grok está mergeado, **Then** hooks/PID/JSON snake_case se comportan igual que hoy.

## Sprint Goal

> Grok reproduce un soundscape propio mientras trabaja y lo corta al idle/Escape. Claude no se toca. El motor dual-host va a upstream; el mp3 de Grok queda en el data dir local.

### Done when

- [ ] PID finder reconoce `grok` — evidence: `grep -n 'grok' bin/claura-control.sh`
- [ ] JSON acepta `sessionId` y `session_id` — evidence: `grep -n 'sessionId' bin/claura-control.sh`
- [ ] `hooks.json` registra `StopCancelled` → idle — evidence: `jq -e '.hooks.StopCancelled' hooks/hooks.json`
- [ ] Data dir contempla `GROK_PLUGIN_DATA` — evidence: `grep -n 'GROK_PLUGIN_DATA' bin/_lib.sh`
- [ ] Config admite `hosts.grok.sound` — evidence: `grep -n 'hosts' bin/claura-player.sh bin/claura-cli.sh`
- [ ] Mp3 de Grok en data dir, no en `audio/` del repo — evidence: `test -f "$CLAURA_DATA/sounds/"*.mp3` y `! git ls-files --error-unmatch audio/grok.mp3`
- [ ] Plugin trusted en Grok — evidence: `grok plugin list` muestra `claura`
- [ ] PR abierto a `scrocchi/claura` — evidence: `gh pr view` del PR
- [ ] Security review de hooks/PID — evidence: informe `security-review`

## Design Decisions

- **Un plugin, players por host.** OpenCode es un puerto nuestro (2026-06-01, `~/.config/opencode/plugins/opencode-aura.js`) que copia el UX de Claura (Glass/Pop, busy/idle) y el `birds.mp3` byte-idéntico, pero en JS sobre la API de eventos de OpenCode. Grok no necesita ese puerto: comparte hooks/marketplace con Claude. Un solo `afplay` haría imposible sonar distinto si ambos hosts trabajan a la vez.
- **Config:** `sound` sigue siendo el default (Claude). `hosts.grok.sound` es el override. Volumen/mute siguen globales.
- **El mp3 no se commitea.** `docs/SOURCES.md` solo admite CC0/CC-BY con fuente verificable. El archivo del usuario (`Downloads/52f259cc…mp3`, encoder Lavf, sin tags, ~30 s) se copia a `${data}/sounds/` y se referencia por nombre. El PR documenta el override, no la pista.
- **PR 1 desde `main` de upstream**, rama `feat/grok-host`. Motor multi-host + adaptador Grok. No se mezcla con #3/#4 ni con `FORK-NOTES.md`.
- **PR 2 `feat/opencode-adapter`**, después. `opencode/plugin.js` llama a `claura-control.sh` con `CLAURA_HOST=opencode` en vez de tener su propio `afplay`. Depende del namespacing de PR 1. OpenCode no habla `hooks.json`; no cabe en el mismo diff sin mezclar runtimes.

## Out of Scope

- Bundlear el mp3 de Grok (o cualquier pista sin ficha en `SOURCES.md`).
- El adaptador OpenCode (PR 2, no este).
- Volumen/mute por host.
- Linux/Windows.
- Marketplace Grok separado (Grok lee `.claude-plugin/`).
