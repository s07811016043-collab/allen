#!/usr/bin/env bash
# Build a blind A/B comparison sheet.
#
#   tools/blind_ab.sh <left.png> <right.png> <out_dir> [seed]
#
# Writes <out_dir>/pair.png with the two frames side by side, labelled only "A"
# and "B" in a randomised order, plus <out_dir>/key.txt recording which is which.
#
# The point is that the agent judging the sheet is given pair.png and NOT
# key.txt. Self-review is worthless if the reviewer knows which image is the one
# it just made — it will find reasons to prefer it. Randomising the side and
# withholding the key is the cheapest way to get an honest answer.
set -euo pipefail

LEFT="$1"; RIGHT="$2"; OUT="$3"; SEED="${4:-0}"
mkdir -p "$OUT"

# Deterministic coin flip from the seed, so a run can be reproduced exactly.
FLIP=$(( (SEED * 1103515245 + 12345) / 65536 % 2 ))
if [ "$FLIP" -eq 0 ]; then A="$LEFT"; B="$RIGHT"; else A="$RIGHT"; B="$LEFT"; fi

H=$(identify -format "%h" "$A")
convert "$A" -resize "x${H}" /tmp/_ab_a.png
convert "$B" -resize "x${H}" /tmp/_ab_b.png

# Matte both on the same neutral field. Judging two frames against different
# backgrounds measures the backgrounds, not the frames.
montage /tmp/_ab_a.png /tmp/_ab_b.png \
  -tile 2x1 -geometry +14+14 -background "#1b1d21" \
  -label "" miff:- \
| convert - -gravity North \
  -background "#1b1d21" -splice 0x34 \
  -fill "#c8ccd4" -pointsize 22 -font DejaVu-Sans \
  -annotate +0+6 "A                                                    B" \
  "$OUT/pair.png"

rm -f /tmp/_ab_a.png /tmp/_ab_b.png

{
  echo "A=$A"
  echo "B=$B"
  echo "seed=$SEED"
} > "$OUT/key.txt"

echo "PAIR $OUT/pair.png"
