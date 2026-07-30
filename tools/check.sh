#!/usr/bin/env bash
# Compile-check the whole Godot project: parses every script and shader, imports
# resources, and exits non-zero if anything failed. Much faster than a capture.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="$ROOT/.tools/Godot_v4.5-stable_linux.x86_64"
export LIBGL_ALWAYS_SOFTWARE=1
LOG=$(mktemp)
timeout 300 xvfb-run -a -s "-screen 0 1280x800x24" \
  "$GODOT" --path "$ROOT/game" --import --rendering-driver opengl3 >"$LOG" 2>&1
# Godot always complains about the absent audio device in a container; that is
# the one error we ignore.
BAD=$(grep -E "SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|shader error|Shader compilation|error\(s\)" "$LOG" \
      | grep -viE "alsa|pulse|audio" | head -40)
rm -f "$LOG"
if [ -n "$BAD" ]; then echo "$BAD"; echo "CHECK_FAILED"; exit 1; fi
echo "CHECK_OK"
