#!/usr/bin/env bash
# Build a release with Godot export templates installed.
# usage: scripts/export.sh [macOS|Windows|Linux|Android]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRESET="${1:-macOS}"
GODOT="${GODOT:-godot}"
case "$PRESET" in
  macOS) OUT="$ROOT/build/macos/SWDA.zip" ;;
  Windows) OUT="$ROOT/build/windows/SWDA.exe" ;;
  Linux) OUT="$ROOT/build/linux/SWDA.x86_64" ;;
  Android) OUT="$ROOT/build/android/SWDA.apk" ;;
  *) echo "unknown preset $PRESET"; exit 1 ;;
esac
mkdir -p "$(dirname "$OUT")"
"$GODOT" --headless --path "$ROOT/game" --export-release "$PRESET" "$OUT"
echo "built $OUT"
