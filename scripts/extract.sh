#!/usr/bin/env bash
# Convert your own copy of the original game into game/assets/extracted.
# usage: scripts/extract.sh /path/to/swda   (the folder that holds SWDA.EXE)
# The folder gets a .gdignore: the game reads these files at runtime and they
# must not go through Godot's importer (or into git).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME_DIR="${1:?usage: scripts/extract.sh <dir containing SWDA.EXE>}"
OUT="$ROOT/game/assets/extracted"
mkdir -p "$OUT"
touch "$OUT/.gdignore"
cd "$ROOT/tools"
python3 -m swdtools extract --game "$GAME_DIR" --out "$OUT" "${@:2}"
