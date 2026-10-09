#!/usr/bin/env bash
# Convert your own copy of the original game into game/assets/extracted.
# usage: scripts/extract.sh /path/to/swda   (the folder that holds SWDA.EXE)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME_DIR="${1:?usage: scripts/extract.sh <dir containing SWDA.EXE>}"
cd "$ROOT/tools"
python3 -m swdtools extract --game "$GAME_DIR" --out "$ROOT/game/assets/extracted" "${@:2}"
if command -v "${GODOT:-godot}" >/dev/null 2>&1; then
  "${GODOT:-godot}" --headless --import --path "$ROOT/game"
else
  echo "Godot not on PATH; open game/ in the editor once to import the assets."
fi
