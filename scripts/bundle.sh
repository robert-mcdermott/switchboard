#!/bin/bash
# Builds Switchboard and assembles an ad-hoc-signed Switchboard.app.
#
#   scripts/bundle.sh [release|debug]
#
# No Xcode project, no Apple Developer account. The result lands in build/Switchboard.app,
# carrying the collector, sbctl, and the scripts that install the collector and download
# the location data.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
case "$CONFIG" in
  release|debug) ;;
  *) echo "usage: scripts/bundle.sh [release|debug]" >&2; exit 2 ;;
esac

VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/SwitchboardCore/Switchboard.swift")"
PREFIX="$(sed -n 's/.*static let identifierPrefix = "\(.*\)".*/\1/p' "$ROOT/Sources/SwitchboardCore/Switchboard.swift")"
IDENTIFIER="$PREFIX.app"

echo "==> Building ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Switchboard.app"
STAGE="$ROOT/build/.stage/Switchboard.app"

echo "==> Assembling $APP"
mkdir -p "$ROOT/build/.stage"
if [ -d "$STAGE" ]; then rm -r "$STAGE"; fi
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN/SwitchboardApp" "$STAGE/Contents/MacOS/Switchboard"
# The collector and sbctl travel inside the app, so a release needs nothing else: the app
# installs the collector from here, and sbctl runs from here.
cp "$BIN/switchboardd" "$BIN/sbctl" "$STAGE/Contents/MacOS/"
# The scripts the app runs: the collector's installer and uninstaller, and the location
# download. Executable, so the app can check they are there and runnable.
install -m 755 "$ROOT/scripts/install.sh" "$STAGE/Contents/Resources/install-collector.sh"
install -m 755 "$ROOT/scripts/uninstall.sh" "$STAGE/Contents/Resources/uninstall-collector.sh"
install -m 755 "$ROOT/scripts/fetch-geoip.sh" "$STAGE/Contents/Resources/fetch-geoip.sh"

# SwiftPM puts each target's resources in <Package>_<Target>.bundle beside the binary.
# Inside an app they belong in Contents/Resources (see RenderResources.swift).
for bundle in "$BIN"/Switchboard_*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$STAGE/Contents/Resources/"
done

# The icon is drawn by scripts/make-icon.swift and committed, so building needs nothing else.
cp "$ROOT/Assets/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Switchboard</string>
  <key>CFBundleDisplayName</key><string>Switchboard</string>
  <key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
  <key>CFBundleExecutable</key><string>Switchboard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad hoc)"
# The helpers first: the app's signature covers them as nested code.
for helper in switchboardd sbctl; do
  codesign --force --sign - --timestamp=none --identifier "$PREFIX.$helper" "$STAGE/Contents/MacOS/$helper"
done
codesign --force --sign - --timestamp=none "$STAGE"
codesign --verify --strict --deep "$STAGE"

if [ -d "$APP" ]; then rm -r "$APP"; fi
mv "$STAGE" "$APP"

echo "==> Done: $APP ($VERSION, $IDENTIFIER)"
