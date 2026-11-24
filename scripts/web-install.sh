#!/bin/bash
# Installs Switchboard from a GitHub release, with no clone, Xcode, or Swift needed:
#
#   curl -fsSL https://github.com/robert-mcdermott/switchboard/releases/latest/download/install.sh | bash
#
# Or read it first (it is short):
#
#   curl -fsSL https://github.com/robert-mcdermott/switchboard/releases/latest/download/install.sh -o install.sh
#   less install.sh
#   bash install.sh
#
# It puts Switchboard.app in /Applications, and asks whether to install the collector
# (Full mode; asks for your password) and download the location databases (about 130 MB
# from db-ip.com). Run it again to update. Options, to skip the questions:
#
#   --collector | --no-collector   install or update the collector, or leave it alone
#   --geoip | --no-geoip           download the location databases, or not
#   --yes                          ask nothing: the app, and an update of an installed collector
#   --dir DIR                      put the app in DIR instead of /Applications
#   --no-open                      do not open the app afterwards
#   --zip FILE                     use a zip already downloaded, still checked against the release
#   --uninstall                    remove the collector and the app; asks before removing your data
#
# This is scripts/web-install.sh in the repository. scripts/release.sh fills in the version
# and the zip's SHA-256 below and publishes the result with each release as install.sh, so
# the zip it installs must match the one built for that release.

set -euo pipefail

# Only macOS's own tools. A program earlier on someone's PATH may not even run here: Intel-only
# builds left in /usr/local/bin by an old Homebrew fail with "Bad CPU type" on a Mac without
# Rosetta. The scripts this runs inherit it.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

VERSION="@VERSION@"
ZIP_SHA256="@ZIP_SHA256@"
REPO="robert-mcdermott/switchboard"
BUNDLE_ID="io.github.robert-mcdermott.switchboard.app"
ZIP_NAME="Switchboard-$VERSION-arm64.zip"
URL="https://github.com/$REPO/releases/download/v$VERSION/$ZIP_NAME"

say() { printf '==> %s\n' "$*"; }
usage() {
  cat <<'USAGE'
Installs or updates Switchboard. Options:
  --collector | --no-collector   install or update the collector, or leave it alone
  --geoip | --no-geoip           download the location databases (about 130 MB), or not
  --yes                          ask nothing: the app, and an update of an installed collector
  --dir DIR                      put the app in DIR instead of /Applications
  --no-open                      do not open the app afterwards
  --zip FILE                     use a zip already downloaded, still checked against the release
  --uninstall                    remove the collector and the app; asks before removing your data
USAGE
}
fail() { printf 'Switchboard: %s\n' "$*" >&2; exit 1; }

# A file's SHA-256, or nothing if it cannot be computed; why goes to the file named second.
# macOS's shasum is a Perl script, so it runs with an empty environment, where no Perl
# settings of the user's (PERL5LIB from local::lib, say) can break it. openssl is the fallback.
sha256_of() {
  local sum
  sum="$(env -i /usr/bin/shasum -a 256 "$1" 2>>"$2")" || sum=""
  sum="${sum%% *}"
  if ! [[ "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    sum="$(/usr/bin/openssl dgst -sha256 -r "$1" 2>>"$2")" || sum=""
    sum="${sum%% *}"
  fi
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || sum=""
  printf '%s' "$sum"
}

DIR="/Applications"
COLLECTOR=""   # yes, no, or empty to ask
GEOIP=""
ASSUME=0
OPEN=1
ZIP=""
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --collector) COLLECTOR=yes ;;
    --no-collector) COLLECTOR=no ;;
    --geoip) GEOIP=yes ;;
    --no-geoip) GEOIP=no ;;
    --yes|-y) ASSUME=1 ;;
    --dir) DIR="${2:?--dir needs a folder}"; shift ;;
    --no-open) OPEN=0 ;;
    --zip) ZIP="${2:?--zip needs a file}"; shift ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option $1 (try --help)" ;;
  esac
  shift
done

APP="$DIR/Switchboard.app"
DATA="$HOME/Library/Application Support/Switchboard"

# Questions go to the terminal even when this script arrives on standard input.
if [ "$ASSUME" -eq 0 ] && [ -t 2 ] && { true </dev/tty; } 2>/dev/null; then TTY=1; else TTY=0; fi
ask() { # question default(y/n) -> 0 for yes. With no one to ask, the answer is no.
  local reply
  if [ "$TTY" -eq 0 ]; then return 1; fi
  if [ "$2" = y ]; then printf '%s [Y/n] ' "$1" >&2; else printf '%s [y/N] ' "$1" >&2; fi
  read -r reply </dev/tty || reply=""
  case "${reply:-$2}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

collector_installed() {
  [ -e /Library/LaunchDaemons/io.github.robert-mcdermott.switchboard.collector.plist ] ||
    [ -e /Library/LaunchDaemons/local.switchboard.collector.plist ]
}

quit_running() {
  pgrep -qf "$APP/Contents/MacOS/Switchboard" || return 0
  say "Quitting the running Switchboard"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -qf "$APP/Contents/MacOS/Switchboard" || return 0
    sleep 0.5
  done
  pkill -f "$APP/Contents/MacOS/Switchboard" || true
}

[ "$(uname -s)" = Darwin ] || fail "Switchboard runs on macOS only."

# --- Removing -------------------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
  if collector_installed; then
    say "Removing the collector (sudo asks for your password)"
    if [ -x "$APP/Contents/Resources/uninstall-collector.sh" ]; then
      sudo "$APP/Contents/Resources/uninstall-collector.sh"
    else
      sudo /bin/bash -c '
        for label in io.github.robert-mcdermott.switchboard.collector local.switchboard.collector; do
          launchctl bootout "system/$label" 2>/dev/null || true
          rm -f "/Library/LaunchDaemons/$label.plist"
        done
        rm -f /usr/local/libexec/switchboardd /var/run/switchboard.sock /var/log/switchboardd.log'
    fi
  fi
  if [ -d "$APP" ]; then
    quit_running
    say "Removing $APP"
    rm -rf "$APP"
  fi
  if [ -d "$DATA" ] && ask "Also remove your connection log, location databases, and settings?" n; then
    say "Removing $DATA and the settings"
    rm -rf "$DATA"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    defaults delete local.switchboard.app >/dev/null 2>&1 || true
  fi
  say "Switchboard is removed."
  exit 0
fi

# --- Installing -----------------------------------------------------------------------

case "$VERSION" in @*) fail "this is the template in the repository. Use the install.sh published with a release, or build from source (see the README)." ;; esac
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] || fail "Switchboard needs a Mac with Apple silicon (M1 or later)."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 15 ] || fail "Switchboard needs macOS 15 or later; this Mac has $(sw_vers -productVersion)."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$ZIP" ]; then
  [ -f "$ZIP" ] || fail "no file at $ZIP"
  cp "$ZIP" "$WORK/$ZIP_NAME"
else
  say "Downloading Switchboard $VERSION"
  curl --fail --location --progress-bar --output "$WORK/$ZIP_NAME" "$URL" || fail "could not download $URL"
fi

say "Checking it against the release's SHA-256"
# A check that cannot run is reported as that, not as a mismatch.
GOT="$(sha256_of "$WORK/$ZIP_NAME" "$WORK/checksum-errors")"
if [ -z "$GOT" ]; then
  sed 's/^/    /' "$WORK/checksum-errors" >&2
  fail "could not compute the download's SHA-256 (neither shasum nor openssl worked), so nothing was installed."
fi
if [ "$GOT" != "$ZIP_SHA256" ]; then
  KIND="$(file -b "$WORK/$ZIP_NAME" | cut -d, -f1)"
  printf '    expected    %s\n    downloaded  %s\n    which is    %s bytes, %s\n' \
    "$ZIP_SHA256" "$GOT" "$(wc -c <"$WORK/$ZIP_NAME" | tr -d ' ')" "$KIND" >&2
  case "$KIND" in
    Zip*) ;;
    *) echo "    That is not a zip: something between this Mac and GitHub, such as a proxy or web filter, sent something else." >&2 ;;
  esac
  fail "the download does not match the release's checksum, so nothing was installed."
fi

ditto -x -k "$WORK/$ZIP_NAME" "$WORK/unpacked" || fail "could not unpack $ZIP_NAME"
NEW="$WORK/unpacked/Switchboard.app"
[ -d "$NEW" ] || fail "the zip holds no Switchboard.app"
if ! SIGNATURE="$(codesign --verify --strict --deep "$NEW" 2>&1)"; then
  printf '%s\n' "$SIGNATURE" | sed 's/^/    /' >&2
  fail "Switchboard.app's signature does not verify, so nothing was installed."
fi

mkdir -p "$DIR"
[ -w "$DIR" ] || fail "cannot write to $DIR. Try --dir \"$HOME/Applications\"."
quit_running
if [ -d "$APP" ]; then
  say "Replacing $APP"
  mv "$APP" "$WORK/previous.app"
else
  say "Installing $APP"
fi
if ! ditto "$NEW" "$APP"; then
  [ -d "$WORK/previous.app" ] && mv "$WORK/previous.app" "$APP"
  fail "could not copy Switchboard.app to $DIR"
fi
# The checksum above has vouched for it. A zip saved by a browser carries macOS's
# quarantine flag, which would block an app that is not notarised.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# The collector: Full mode sees every account's connections and their hostnames. One
# already installed is updated, so it matches the app.
if [ -z "$COLLECTOR" ]; then
  if collector_installed; then
    COLLECTOR=yes
    say "The collector is installed; updating it to match (sudo asks for your password)"
  elif ask "Install the collector, to see every account's connections and hostnames? It runs as root and asks for your password." n; then
    COLLECTOR=yes
  else
    COLLECTOR=no
  fi
fi
if [ "$COLLECTOR" = yes ]; then
  sudo "$APP/Contents/Resources/install-collector.sh" ||
    say "The collector was not installed. Switchboard's Health tab can install it later."
fi

# Location data, if there is none yet.
if [ -z "$GEOIP" ]; then
  if ls "$DATA/GeoIP/"*.mmdb >/dev/null 2>&1; then
    GEOIP=no
  elif ask "Download the location databases (about 130 MB from db-ip.com) for countries, cities, and network owners?" y; then
    GEOIP=yes
  else
    GEOIP=no
  fi
fi
if [ "$GEOIP" = yes ]; then
  "$APP/Contents/Resources/fetch-geoip.sh" || say "The location download failed; Settings ▸ Location can try again."
fi

echo
say "Switchboard $VERSION is installed in $DIR."
echo "    sbctl, the terminal viewer:  $APP/Contents/MacOS/sbctl"
echo "    Update: run this installer again. Remove everything:"
echo "    curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- --uninstall"
[ "$OPEN" -eq 1 ] && open "$APP"
exit 0
