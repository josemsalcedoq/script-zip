#!/usr/bin/env bash
# Importa los bundles y hace fast-forward de cada repo (working tree limpio).
# Uso: ./laptop-import.sh [RUTA_REPO] [CARPETA_BUNDLES]
set -euo pipefail

ROOT="${1:-/Users/danieldelgado/Documents/mercel/repositories/life2lifeJun26/health-gbp-main-master}"
BDIR="${2:-$HOME/Downloads/l2l-bundles}"

[ -d "$ROOT/.git" ] || { echo "ERROR: no encuentro el repo en $ROOT"; exit 1; }
[ -d "$BDIR" ]      || { echo "ERROR: no encuentro los bundles en $BDIR"; exit 1; }

cd "$ROOT"
repos=(.)
for d in packages/*/; do [ -d "${d}.git" ] && repos+=("${d%/}"); done

need_full=0
for r in "${repos[@]}"; do
  name=$([ "$r" = "." ] && echo _root || basename "$r")
  b="$BDIR/$name.bundle"
  [ -f "$b" ] || { echo "-- $name: sin bundle (sin cambios u omitido)"; continue; }
  echo ">> $name"
  (
    cd "$r"
    # el bundle incremental requiere que el commit base ya exista aqui
    if ! git bundle verify "$b" >/dev/null 2>&1; then
      echo "   ERROR: falta el commit base para este bundle."
      echo "          pide un export COMPLETO en la VDI:  FULL=1 ...vdi-sync.sh"
      exit 3
    fi
    git fetch --quiet "$b" 'refs/remotes/origin/*:refs/remotes/origin/*'
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [ -n "$up" ]; then
      if git merge --ff-only "$up" >/dev/null 2>&1; then
        echo "   ff -> $up ($(git rev-parse --short HEAD))"
      else
        echo "   AVISO: la rama divergio de $up; revisa:  git log --oneline HEAD..$up"
      fi
    else
      echo "   (rama sin upstream; refs origin/* actualizadas, revisa a mano)"
    fi
  ) || need_full=1
done

echo
if [ "$need_full" -ne 0 ]; then
  echo "Algun repo necesita un export COMPLETO (FULL=1) en la VDI."
else
  echo "Hecho. Ya ves en git los cambios de los demas, repo por repo."
fi
