#!/bin/bash
# Builds a release: an unsigned zip of the app, the collector, sbctl and the scripts,
# with SHA-256 checksums. Publishes nothing; the zip is left in build/release.
#
#   scripts/release.sh
#
# The app is signed ad hoc, not with a Developer ID, and is not notarised. Someone who
# downloads the zip must clear macOS's quarantine flag before it will open; the README
# inside the zip says how. Building from source avoids that step entirely.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/SwitchboardCore/Switchboard.swift")"
NAME="Switchboard-$VERSION"
OUT="$ROOT/build/release"
STAGE="$OUT/$NAME"

echo "==> Testing"
swift test --package-path "$ROOT" 2>&1 | tail -1

echo "==> Building $NAME"
"$ROOT/scripts/bundle.sh" >/dev/null
swift build --package-path "$ROOT" -c release --product sbctl >/dev/null
swift build --package-path "$ROOT" -c release --product switchboardd >/dev/null
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"

rm -rf "$STAGE" "$OUT/$NAME.zip"
mkdir -p "$STAGE/bin" "$STAGE/scripts"
ditto "$ROOT/build/Switchboard.app" "$STAGE/Switchboard.app"
cp "$BIN/sbctl" "$BIN/switchboardd" "$STAGE/bin/"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$ROOT/scripts/fetch-geoip.sh" "$STAGE/scripts/"
cp "$ROOT/docs/GUIDE.md" "$STAGE/GUIDE.md"

cat > "$STAGE/README.txt" <<TEXT
Switchboard $VERSION
====================

A live picture of every network connection on this Mac.

This build is not signed with a Developer ID and is not notarised, so macOS will
refuse to open it until you remove the quarantine flag your browser added:

    xattr -dr com.apple.quarantine Switchboard.app bin

Then open Switchboard.app. To see every account's connections and hostnames,
install the collector (it asks for your password):

    sudo scripts/install.sh --binary bin/switchboardd

and remove it again with:

    sudo scripts/uninstall.sh

Check the download first against SHA256SUMS:

    shasum -a 256 -c SHA256SUMS

GUIDE.md covers everything else.
TEXT

echo "==> Checksums and zip"
(cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
(cd "$OUT" && ditto -c -k --keepParent "$NAME" "$NAME.zip")
(cd "$OUT" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "==> Done"
ls -lh "$OUT/$NAME.zip"
cat "$OUT/$NAME.zip.sha256"
