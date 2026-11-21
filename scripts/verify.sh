#!/bin/bash
# Runs the M1 exit test: the live engine against netstat and against traffic it generates.
#
#   scripts/verify.sh
#
# netstat has to be run from here rather than from sbctl: launched by an unprivileged,
# ad-hoc-signed process it prints no internet sockets (docs/spikes/M0-findings.md, S1).
# sbctl asks for it by creating a request file at the moment it has taken its own sample.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" >/dev/null
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"

WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT
HANDSHAKE="$WORK/netstat.txt"

"$BIN/sbctl" verify --netstat-handshake "$HANDSHAKE" &
VERIFY=$!

while kill -0 "$VERIFY" 2>/dev/null; do
  if [ -e "$HANDSHAKE.request" ] && [ ! -e "$HANDSHAKE" ]; then
    /usr/sbin/netstat -anv > "$HANDSHAKE.partial"
    mv "$HANDSHAKE.partial" "$HANDSHAKE"
  fi
  /bin/sleep 0.02
done
wait "$VERIFY"
