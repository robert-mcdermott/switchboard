#!/bin/bash
# Renders the reference scenarios with no window and compares them with the golden images.
#
#   scripts/snapshots.sh            compare; non-zero exit if any picture has changed
#   scripts/snapshots.sh --update   accept the current rendering as the new reference
#
# The scenarios are simulated on a fixed clock, so the same code draws the same pixels.
# Goldens are specific to the GPU and system fonts they were made with: after changing
# machine or macOS version, look at the new images and run --update.

set -euo pipefail

MODE="${1:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" >/dev/null
APP="$(swift build --package-path "$ROOT" --show-bin-path)/SwitchboardApp"

OUT="$ROOT/build/snapshots"
GOLDEN="$ROOT/Tests/Goldens"
mkdir -p "$OUT" "$GOLDEN"

status=0
# name, scenario, layout, and colour theme of each reference picture.
for entry in "quiet quiet constellation standard" "developer developer constellation standard" \
             "stress stress constellation standard" "flow developer flow standard" "lanes developer lanes standard" \
             "globe developer globe standard" "hierarchy developer hierarchy standard" \
             "neon-globe developer globe neon"; do
  set -- $entry
  name="$1"; scenario="$2"; layout="$3"; palette="$4"
  "$APP" --snapshot "$OUT/$name.png" --source "sim:$scenario" --layout "$layout" --palette "$palette" --at 20 --size 1200x750 >/dev/null
  if [ "$MODE" = "--update" ]; then
    cp "$OUT/$name.png" "$GOLDEN/$name.png"
    echo "UPDATED $name"
  elif [ ! -f "$GOLDEN/$name.png" ]; then
    echo "MISSING $name: no golden image; run scripts/snapshots.sh --update"
    status=1
  else
    printf '%-10s ' "$name"
    "$APP" --diff "$OUT/$name.png" "$GOLDEN/$name.png" || status=1
  fi
done
exit $status
