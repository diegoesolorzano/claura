# Plan: Claura en Grok

**Feature ID:** claura-grok-host
**Repo:** claura
**Issue:** none
**Upstream:** docs/specs/claura-grok-host.md
**Date:** 2026-08-17
**Status:** Planned

**Tier:** standard
**Modifiers:** security-review

## Overview

Extender el plugin existente para que Claude y Grok compartan data dir y config, con player y sesiones namespaced por host. Grok entra por el mismo `hooks.json` (eventos extra que Claude ignora). El mp3 de Grok no se commitea. Rama `feat/grok-host` desde `upstream/main`.

## Sprint Goal

_Quoted from the spec._

> Grok reproduce un soundscape propio mientras trabaja y lo corta al idle/Escape. Claude no se toca. El motor dual-host va a upstream; el mp3 de Grok queda en el data dir local.

### Done when

- [ ] PID finder reconoce `grok` — evidence: `grep -n 'grok' bin/claura-control.sh`
- [ ] JSON acepta `sessionId` y `session_id` — evidence: `grep -n 'sessionId' bin/claura-control.sh`
- [ ] `hooks.json` registra `StopCancelled` → idle — evidence: `jq -e '.hooks.StopCancelled' hooks/hooks.json`
- [ ] Data dir contempla `GROK_PLUGIN_DATA` — evidence: `grep -n 'GROK_PLUGIN_DATA' bin/_lib.sh`
- [ ] Config admite `hosts.grok.sound` — evidence: `grep -n 'hosts' bin/claura-player.sh bin/claura-cli.sh`
- [ ] Mp3 de Grok en data dir, no en `audio/` del repo — evidence: local file + `! git ls-files --error-unmatch audio/grok.mp3`
- [ ] Plugin trusted en Grok — evidence: `grok plugin list` muestra `claura`
- [ ] PR abierto a `scrocchi/claura` — evidence: `gh pr view`
- [ ] Security review de hooks/PID — evidence: informe `security-review`

## Shared Types

```bash
# Host id: lowercase [a-z0-9-]+. Known values: claude | grok.
# CLAURA_HOST overrides detection (PR 2 / OpenCode will set this).

claura_detect_host()          # → stdout host
claura_sanitize_host "$raw"   # → stdout host | claude if empty/invalid
claura_json_get "$json" k1 k2 # → first non-empty jq path
claura_cfg_host_sound "$host" # → hosts.$host.sound // sound // birds
claura_find_host_pid "$ppid"  # → pid of claude|grok|grok-* ancestor, or empty
claura_player_pid_file "$host"
claura_sessions_dir "$host"
claura_stop_player            # optional host; omit = all hosts
```

State layout:

```
${data}/state/sessions/${host}/${sid}
${data}/state/sessions/${host}/${sid}.cpu
${data}/state/baseline/${host}/${sid}
${data}/state/player.${host}.pid
${data}/state/player.${host}.root
```

## Tasks

### Task 1: Helpers de host en `_lib.sh` + tests
- **Files:** `bin/_lib.sh` (modify), `tests/host.sh` (create), `tests/run.sh` (create), `.github/workflows/validate.yml` (modify)
- **Produces:** las funciones de Shared Types
- **Do:** Extraer detección de host, parseo JSON camelCase/snake_case, sound-por-host, PID walker (`claude`|`grok`|`grok-*`), paths namespaced, `claura_stop_player` que mata todos los `player.*.pid` (y el legacy `player.pid`). `claura_data_dir`: `CLAURA_DATA_DIR` → dirs bootstrapped bajo `$HOME/.claude/plugins/data/claura*` y `$HOME/.grok/plugins/data/claura*` → `GROK_PLUGIN_DATA` → `CLAUDE_PLUGIN_DATA` → `$HOME/.claude/plugins/data/claura`. Si hay un bootstrapped, reutilizarlo (config compartida). Tests con `HOME` temporal. TDD.
- **Verify:** `bash tests/run.sh` exit 0; `shellcheck -s bash bin/_lib.sh`
- **Tests:** Yes
- **Depends on:** None

### Task 2: Controlador namespaced
- **Files:** `bin/claura-control.sh` (modify)
- **Do:** Leer `sessionId // session_id` y `hookEventName // hook_event_name`. Host via `claura_detect_host`. Escribir sesiones bajo `sessions/$host/`. Spawn `CLAURA_HOST=$host` player. Reconcile solo ese host. Killswitch de root por `player.$host.root`. Compat: archivos sueltos en `sessions/` se tratan como `claude` o se dejan expirar (MAX_STALE).
- **Verify:** `bash -n bin/claura-control.sh`; `shellcheck -s bash bin/claura-control.sh`
- **Tests:** Yes — JSON/host via tests/host.sh; no spawn de afplay en unit
- **Depends on:** Task 1

### Task 3: Player por host
- **Files:** `bin/claura-player.sh` (modify)
- **Do:** `CLAURA_HOST` (default `claura_detect_host`). Sound = `claura_cfg_host_sound`. Pid/root/baseline/sessions namespaced. Sampler usa el PID guardado (ya es el host).
- **Verify:** `bash -n` + shellcheck
- **Tests:** No (loop + afplay; sound resolution cubierto en Task 1)
- **Depends on:** Task 1

### Task 4: Hooks Grok
- **Files:** `hooks/hooks.json` (modify), `bin/claura-chime.sh` (create)
- **Do:** `StopCancelled` → `claura-control.sh idle`. `Notification` matcher `permission_prompt` → Pop + idle (dejar matcher `*` → idle). `Stop` Glass pasa por `claura-chime.sh stop` que solo suena si `reason` está vacío (Claude) o es `end_turn` (evita ding en el Stop de teardown de Grok).
- **Verify:** `jq -e '.hooks.StopCancelled' hooks/hooks.json`; `claude plugin validate --strict .` (si rejecta el evento desconocido, documentar y dejar el evento — Grok lo necesita; fallback CPU cubre Escape)
- **Tests:** Yes — chime script con fixtures JSON
- **Depends on:** Task 2

### Task 5: CLI + menu
- **Files:** `bin/claura-cli.sh` (modify), `commands/menu.md` (modify)
- **Do:** `status` añade `host` y `hosts`. `set sound NAME [host]`: host explícito o `claura_detect_host` (si no es `claude`, escribe `hosts.$host.sound`; si es `claude`, escribe `sound`). `off`/`mute`/`set volume` llaman `claura_stop_player` (todos).
- **Verify:** `CLAURA_DATA_DIR=... CLAURA_HOST=grok bin/claura-cli.sh set sound birds grok` y `jq` del status
- **Tests:** Yes
- **Depends on:** Task 1

### Task 6: Docs + version
- **Files:** `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- **Do:** Documentar install Grok, sonido por host, que el override vive en data dir. Version `0.1.1`. No commitear el mp3.
- **Verify:** grep README por Grok; version 0.1.1 en ambos manifests
- **Tests:** No
- **Depends on:** Tasks 1–5

### Task 7: Install local Grok + pista
- **Files:** none in repo. Copy `/Users/diego/Downloads/52f259cc030f48ec99de19c84442a925.mp3` → `~/.claude/plugins/data/claura-claura-marketplace/sounds/grok.mp3`. `hosts.grok.sound=grok`. `grok plugin marketplace add` del checkout, `install --trust`, enable.
- **Verify:** `test -f .../sounds/grok.mp3`; `grok plugin list` muestra claura; `! git ls-files --error-unmatch audio/grok.mp3`
- **Tests:** No
- **Depends on:** Task 6
- **Risky:** yes (escribe `~/.grok` y el data dir)

### Task 8: PR a scrocchi/claura
- **Files:** none
- **Do:** Commit atómicos en `feat/grok-host` desde `upstream/main`. Sin `FORK-NOTES`, sin `docs/specs/`, sin el mp3. Push a `diegoesolorzano/claura` y `gh pr create` contra `scrocchi/claura`.
- **Verify:** `gh pr view`
- **Depends on:** Tasks 1–6
- **Risky:** yes

### Task 9: Revisión de seguridad final
- **Files:** none (read-only review)
- **Do:** Invoke `security-review` sobre el diff. Entry points: hooks (`StopCancelled`, `permission_prompt`, chime), `claura-cli.sh set sound [host]`, walker de PIDs, writes a `${data}/state/sessions/$host/`. Quién llama: el host (Claude/Grok) al disparar hooks; el usuario via `/claura:menu`. Prioridad: path traversal en `host`/`session_id`, matar PIDs ajenos, dos data dirs.
- **Verify:** tabla de 7 checks con comando+output. Cero CRITICAL, o fix task aparte.
- **Depends on:** all implementation tasks
- **Risky:** yes

## Test Matrix

### Shared Test Infrastructure
- **Framework:** bash scripts (`tests/run.sh`), sin bats
- **Fixtures:** `HOME` temporal, `CLAURA_DATA_DIR`, JSON de hook Claude vs Grok
- **CI:** añadir `bash tests/run.sh` a `validate.yml`

### Acceptance Criteria → Test Mapping

| AC | Test Location | Case |
|----|--------------|------|
| JSON Grok identifica sesión | `tests/host.sh` | `sessionId` camelCase |
| PID grok | `tests/host.sh` | comm match `grok` / `grok-*` |
| Sonido por host | `tests/host.sh` | `hosts.grok.sound` vs default |
| Data dir compartido | `tests/host.sh` | bootstrapped Claude gana sobre GROK_PLUGIN_DATA vacío |
| Claude no cambia | `tests/host.sh` | snake_case + host=claude sin GROK_* |
| Chime no suena en teardown | `tests/chime.sh` | `reason=channel_closed` → no play |

## Risks

- `claude plugin validate --strict` puede rechazar `StopCancelled`. Si pasa: dejar el evento (Grok lo necesita) y abrir issue; el sampler de CPU cubre Escape en ~10s.
- `ps -o comm=` de Grok puede ser `grok-1.0.4-macos-aarch64` — el case `grok-*` lo cubre.
- `[compat.claude] hooks = false` en `~/.grok/config.toml`: los hooks de Claude NO se heredan. Hay que instalar el plugin en Grok (Task 7).
- `claura_stop_player` hoy solo mata `player.pid`. Si no se extiende, mute/off deja vivo el player de Grok.

## Review Notes

Revisión adversarial hecha contra el spec y el código de `upstream/main` (no contra `personal/build`). Cambios incorporados al plan:

- Data dir: preferir bootstrapped existente para no crear un segundo árbol bajo `~/.grok/plugins/data`.
- `claura_stop_player` debe matar todos los hosts (mute/off).
- Chime de Stop filtrado por `reason` (Grok dispara Stop en teardown).
- `CLAURA_HOST` override ahora (desbloquea PR 2 OpenCode sin otro cambio de contrato).
- Validate `--strict` tratado como riesgo, no como supuesto.
- Install Grok es obligatorio: compat Claude hooks está apagado en esta máquina.
