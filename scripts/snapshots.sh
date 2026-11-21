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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" >/dev/null
APP="$(swift build --package-path "$ROOT" --show-bin-path)/SwitchboardApp"

OUT="$ROOT/build/snapshots"
GOLDEN="$ROOT/Tests/Goldens"
mkdir -p "$OUT" "$GOLDEN"

status=0
for scenario in quiet developer stress; do
  "$APP" --snapshot "$OUT/$scenario.png" --source "sim:$scenario" --at 20 --size 1200x750 >/dev/null
  if [ "${1:-}" = "--update" ]; then
    cp "$OUT/$scenario.png" "$GOLDEN/$scenario.png"
    echo "UPDATED $scenario"
  elif [ ! -f "$GOLDEN/$scenario.png" ]; then
    echo "MISSING $scenario: no golden image; run scripts/snapshots.sh --update"
    status=1
  else
    printf '%-10s ' "$scenario"
    "$APP" --diff "$OUT/$scenario.png" "$GOLDEN/$scenario.png" || status=1
  fi
done
exit $status
