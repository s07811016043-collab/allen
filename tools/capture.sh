#!/usr/bin/env bash
# Petalia capture harness.
#
#   tools/capture.sh --species=cat --growth=0 --out=_captures/kitten.png [--size=720x720] ...
#
# Renders one deterministic frame of the game with a software GL stack under a
# virtual X server, so agents can look at the actual product in a container with
# no GPU and no display.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="$ROOT/.tools/Godot_v4.5-stable_linux.x86_64"
SIZE="720x720"
ARGS=()
OUT=""
for a in "$@"; do
  case "$a" in
    --size=*) SIZE="${a#*=}" ;;
    --out=*)
      OUT="${a#*=}"
      # Godot resolves bare relative paths against res://, which silently drops
      # the file inside the project. Always hand it an absolute path.
      case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
      mkdir -p "$(dirname "$OUT")"
      ARGS+=("--out=$OUT")
      ;;
    *)        ARGS+=("$a") ;;
  esac
done

export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
LOG=$(mktemp)
timeout 300 xvfb-run -a -s "-screen 0 1920x1200x24" \
  "$GODOT" --path "$ROOT/game" res://tools/capture/capture.tscn \
  --rendering-driver opengl3 --resolution "$SIZE" --single-window \
  -- "${ARGS[@]}" >"$LOG" 2>&1
rc=$?
# Godot is noisy about missing audio devices in containers; surface only what
# matters — script errors, shader errors, and the capture confirmation.
grep -E "CAPTURE_OK|SCRIPT ERROR|ERROR:|Parser Error|shader|Invalid|Cannot|expected" "$LOG" \
  | grep -viE "alsa|pulse|audio|v-sync|vsync" | head -40
rm -f "$LOG"
if [ -n "$OUT" ] && [ ! -f "$OUT" ]; then echo "CAPTURE_FAILED $OUT"; exit 1; fi
exit $rc
