#!/usr/bin/env bash
# Emite l2l-have.txt (HEAD actual por repo) para el sync incremental.
# Uso: ./laptop-prep.sh [RUTA_REPO] [ARCHIVO_SALIDA]
set -euo pipefail

ROOT="${1:-/Users/danieldelgado/Documents/mercel/repositories/life2lifeJun26/health-gbp-main-master}"
OUTFILE="${2:-$PWD/l2l-have.txt}"

[ -d "$ROOT/.git" ] || { echo "ERROR: no encuentro el repo en $ROOT"; exit 1; }

cd "$ROOT"
repos=(.)
for d in packages/*/; do [ -d "${d}.git" ] && repos+=("${d%/}"); done

: > "$OUTFILE"
for r in "${repos[@]}"; do
  name=$([ "$r" = "." ] && echo _root || basename "$r")
  sha=$(cd "$r" && git rev-parse --verify --quiet HEAD || true)
  [ -n "$sha" ] && echo "$name $sha" >> "$OUTFILE"
done

echo "Escrito $(wc -l < "$OUTFILE") repos en $OUTFILE"
