#!/usr/bin/env bash
# Win rate of every slime troop type against every human troop type
# (30 v 30, line + charge, both sides AI-timed specials, generals per AI).
# Usage (from gate-fall-game/):  tools/troop_matrix.sh [runs]
# GODOT = path to the Godot 4.7 binary (default: the macOS app).
set -u
RUNS="${1:-150}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
OUT="tools/troop_matrix_out.txt"
: > "$OUT"
for s in slime_big slime_mage slime_hopper; do
  for k in knight archer cavalry; do
    echo "=== S:$s vs K:$k ===" | tee -a "$OUT"
    "$GODOT" --headless --path . --script res://tools/run_sims.gd -- \
      --runs="$RUNS" --side=S --form=line --orders=charge --rows=on \
      --cast=ai --gcharge=ai --units="$s:30" --enemy-units="$k:30" 2>/dev/null \
      | grep -v '^Godot\|^$' | tee -a "$OUT"
  done
done
echo "saved to $OUT"
