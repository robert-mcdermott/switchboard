#!/bin/bash
# Builds a release for Apple silicon and, when asked, publishes it on GitHub.
#
#   scripts/release.sh             test and build; leaves the release in build/release
#   scripts/release.sh --publish   then create the GitHub release v<version> from it
#
# A release is three files:
#   Switchboard-<version>-arm64.zip   the app, carrying the collector, sbctl, and their scripts
#   install.sh                        scripts/web-install.sh, with the version and the zip's
#                                     SHA-256 filled in, so it installs only that zip
#   SHA256SUMS                        checksums of both
# and its notes, docs/releases/<version>.md.
#
# The app is signed ad hoc, not with a Developer ID, and is not notarised. install.sh
# downloads with curl, which macOS does not quarantine, so the app opens without a
# Gatekeeper prompt; a zip saved by a browser needs Open Anyway in System Settings ▸
# Privacy & Security once.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/SwitchboardCore/Switchboard.swift")"
TAG="v$VERSION"
OUT="$ROOT/build/release"
ZIP="Switchboard-$VERSION-arm64.zip"
NOTES="$ROOT/docs/releases/$VERSION.md"

PUBLISH=0
case "${1:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  *) echo "usage: scripts/release.sh [--publish]" >&2; exit 2 ;;
esac

if [ "$PUBLISH" -eq 1 ]; then
  # A release is built from exactly what is on GitHub's main branch.
  command -v gh >/dev/null || { echo "publishing needs the GitHub CLI, gh" >&2; exit 1; }
  [ -f "$NOTES" ] || { echo "no release notes at $NOTES" >&2; exit 1; }
  [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || { echo "commit your changes first" >&2; exit 1; }
  [ "$(git -C "$ROOT" branch --show-current)" = main ] || { echo "release from main" >&2; exit 1; }
  git -C "$ROOT" fetch -q origin main
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] || { echo "push main first" >&2; exit 1; }
  if git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "$TAG is already released; raise the version in Sources/SwitchboardCore/Switchboard.swift" >&2
    exit 1
  fi
fi

echo "==> Testing"
swift test --package-path "$ROOT" 2>&1 | tail -1

# The website is built from the guide; a broken link in it stops the release.
echo "==> Checking the website builds"
if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
  node "$ROOT/scripts/site/build.mjs" --out "$ROOT/build/site"
else
  echo "    skipped: it needs Node.js 22 or later"
fi

echo "==> Building Switchboard $VERSION"
"$ROOT/scripts/bundle.sh" >/dev/null

rm -rf "$OUT"
mkdir -p "$OUT"
# No extended attributes or resource forks: nothing in the app needs them, and they are
# not part of its signature.
ditto -c -k --keepParent --norsrc --noextattr "$ROOT/build/Switchboard.app" "$OUT/$ZIP"
SHA="$(shasum -a 256 "$OUT/$ZIP" | cut -d' ' -f1)"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@ZIP_SHA256@/$SHA/g" "$ROOT/scripts/web-install.sh" > "$OUT/install.sh"
chmod 755 "$OUT/install.sh"
if grep -q '@VERSION@\|@ZIP_SHA256@' "$OUT/install.sh"; then
  echo "install.sh still has a placeholder" >&2
  exit 1
fi
(cd "$OUT" && shasum -a 256 "$ZIP" install.sh > SHA256SUMS)

# What a person will get must unpack and verify.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$OUT/$ZIP" "$CHECK"
codesign --verify --strict --deep "$CHECK/Switchboard.app"
for part in MacOS/Switchboard MacOS/switchboardd MacOS/sbctl Resources/install-collector.sh Resources/uninstall-collector.sh Resources/fetch-geoip.sh; do
  [ -x "$CHECK/Switchboard.app/Contents/$part" ] || { echo "the zip is missing $part" >&2; exit 1; }
done

echo "==> Built"
ls -lh "$OUT"
cat "$OUT/SHA256SUMS"

if [ "$PUBLISH" -eq 1 ]; then
  echo "==> Publishing $TAG"
  gh release create "$TAG" "$OUT/$ZIP" "$OUT/install.sh" "$OUT/SHA256SUMS" \
    --repo robert-mcdermott/switchboard --target "$(git -C "$ROOT" rev-parse HEAD)" \
    --title "Switchboard $VERSION" --notes-file "$NOTES"
  echo "==> Next, publish the website for $VERSION (scripts/site/README.md):"
  echo "    node scripts/site/build.mjs --publish ../switchboard-site"
fi
