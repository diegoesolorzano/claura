# Notas del fork — diegoesolorzano/claura

Fork de [scrocchi/claura](https://github.com/scrocchi/claura), el plugin de audio ambiental
para Claude Code (MIT). A diferencia del fork de orca, este **no** busca diferenciación de
producto: existe solo para tener los parches aplicados mientras upstream los revisa, y para
poder reaplicarlos cuando `claude plugin update` pise la copia instalada.

> Este archivo vive SOLO en la rama `personal/build`. Nunca debe llegar a una rama de PR.

## Estrategia

- **Upstream-first, sin excepción.** Todo lo que hay aquí ya está propuesto upstream. Si los
  PRs entran, este fork se queda sin razón de ser y `personal/build` se vuelve un alias de
  `main`.
- **Una rama por fix**, mergeada a `personal/build`. Las ramas de PR nunca llevan este archivo.
- El repo instalado que Claude Code ejecuta NO es este: es
  `~/.claude/plugins/cache/claura-marketplace/claura/0.1.0/`. Este repo es la fuente para
  reparchearlo (ver *Reaplicar el parche local*).

## Ramas

| Rama | Contenido | PR |
|---|---|---|
| `main` | upstream limpio | — |
| `fix/orphaned-lock-deadlock` | deadlock del lock | [#3](https://github.com/scrocchi/claura/pull/3) → issue [#2](https://github.com/scrocchi/claura/issues/2) |
| `fix/data-dir-resolution` | resolución del data dir | [#4](https://github.com/scrocchi/claura/pull/4) → issue [#1](https://github.com/scrocchi/claura/issues/1) |
| `personal/build` | ambos fixes mergeados — **esto es lo instalado localmente** | — |

## Los parches

### 1. Lock huérfano deja el plugin mudo para siempre (`bin/claura-control.sh`)

El controlador toma el lock con `mkdir "$LOCK_DIR"` y escribe el PID del dueño en la línea
siguiente, con el trap `EXIT` armado después de eso. Si el proceso muere en esa ventana queda
un `lock.d` sin `owner` y sin trap que lo limpie. La ruta de robo está condicionada a
`[[ -f "$LOCK_DIR/owner" ]]`, así que nunca puede reclamarlo: cada hook posterior gira los 5s
de `LOCK_TIMEOUT_SECS` y sale con `exit 0` sin reconciliar. El player no se respawnea nunca más.

Pasó en esta instalación el 2026-07-30 16:52 y el audio estuvo muerto hasta el 2026-08-01.
Síntoma visible: `SessionEnd hook [...] failed: Hook cancelled` y procesos `claura-control.sh
working` acumulándose. La config seguía válida todo el tiempo, lo que despista el diagnóstico.

El fix: trap armado justo después del `mkdir`; robo de un lock sin `owner` cuando supera
`STALE_LOCK_SECS` (10s, única vía de recuperación ante `SIGKILL` o un hook que el host corta);
y log incondicional del timeout de adquisición en `state/events.log`, porque el `exit 0`
silencioso hacía que un deadlock permanente se viera igual que la operación normal.

### 2. El CLI directo resuelve un directorio fantasma (`bin/_lib.sh`)

`claura_data_dir()` caía a un `~/.claude/plugins/data/claura` hardcodeado, pero Claude Code
exporta `CLAUDE_PLUGIN_DATA` apuntando a `data/<plugin>-<marketplace>` y solo a hooks y slash
commands. Correr `bin/claura-cli.sh` desde la terminal — que el propio README documenta — leía
y escribía un directorio que no existe en la práctica: `status` reportaba config obsoleta y
`set sound` / `set volume` parecían no hacer nada.

El fix: orden `CLAURA_DATA_DIR` → `CLAUDE_PLUGIN_DATA` → autodescubrimiento → default legacy.
El descubrimiento canonicaliza con `pwd -P` y deduplica, así que el symlink
`data/claura` → `data/claura-claura-marketplace` colapsa a un solo candidato. Con varios
candidatos reales lista todos por stderr y dice cuál eligió en vez de adivinar callado.

También corregidos README y `docs/MIGRATION.md`, este último porque el paso 3 hace `touch
.legacy-cleared` desde shell: con el bug, ese marcador caía en el fantasma y dejaba el plugin
inerte creyendo que lo habías limpiado.

## Compatibilidad

macOS trae **bash 3.2**. Sin arrays (`"${arr[@]}"` con array vacío bajo `set -u` revienta ahí),
sin `declare -A`, sin `${var^^}`. Verificar con `/bin/bash` real, no con el de Homebrew.

## Reaplicar el parche local

`claude plugin update` sobrescribe el directorio instalado y se lleva los parches. Para
reaplicarlos desde este repo:

```sh
cd /Volumes/External/Workspace/PERSONALES-GIT/claura
git checkout personal/build
DEST=~/.claude/plugins/cache/claura-marketplace/claura/0.1.0
cp bin/claura-control.sh bin/_lib.sh "$DEST/bin/"
cp README.md "$DEST/README.md"
cp docs/MIGRATION.md "$DEST/docs/MIGRATION.md"
```

Toma efecto en el siguiente hook; no hace falta reiniciar Claude Code. Verificar con:

```sh
"$DEST/bin/claura-cli.sh" status | jq -r .data_dir   # debe ser claura-claura-marketplace
```

Si la versión instalada dejó de ser `0.1.0`, rebasar `personal/build` sobre el tag nuevo antes
de copiar — los parches podrían ya estar aplicados upstream.

## Sincronizar con upstream

```sh
git fetch upstream
git checkout main && git merge --ff-only upstream/main
git checkout personal/build && git rebase main
```

Si upstream mergeó los PRs, las ramas `fix/*` quedan absorbidas y `personal/build` no debería
tener commits propios: ahí este fork ya no hace falta.

## Diagnóstico rápido

Cuando claura deje de sonar:

```sh
D=~/.claude/plugins/data/claura-claura-marketplace/state
ls -la "$D/lock.d" 2>/dev/null        # existe sin `owner` dentro → lock huérfano
cat "$D/events.log" 2>/dev/null       # líneas `lock-timeout` → el lock es el problema
ls "$D/sessions/"                     # vacío con sesiones activas → no está reconciliando
pgrep -fl afplay                      # sin proceso → el player no está corriendo
```

Con el parche #1 aplicado el lock huérfano se recupera solo en el siguiente hook. Si aun así
aparece `lock-timeout` repetido, hay un controlador vivo colgado: `pgrep -fl claura-control`.
