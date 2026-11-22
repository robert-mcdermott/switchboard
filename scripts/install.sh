#!/bin/bash
# Installs the Switchboard collector as a system service.
#
#   sudo scripts/install.sh                                build from source and install
#   sudo scripts/install.sh --binary path/to/switchboardd  install a collector built elsewhere
#
# A copy of this script travels inside Switchboard.app as install-collector.sh. Run from
# there (the app's Install Collector button does that) it installs the collector the app
# carries, so nothing is built.
#
# What it does, and nothing else:
#   1. builds switchboardd if it is not built (as you, not as root), unless the app carries one
#   2. copies it to /usr/local/libexec/switchboardd, owned by root
#   3. writes /Library/LaunchDaemons/<label>.plist
#   4. starts it, and has launchd keep it running
#
# A collector installed by a build before 0.1.0, under the label local.switchboard.collector,
# is stopped and its file removed first. The uninstall script reverses every step.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This installs a system service, so it needs sudo:  sudo $0" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LABEL="io.github.robert-mcdermott.switchboard.collector"
OLD_LABEL="local.switchboard.collector"
BINARY="/usr/local/libexec/switchboardd"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG="/var/log/switchboardd.log"
SOCKET="/var/run/switchboard.sock"

if [ "${1:-}" = "--binary" ] && [ -n "${2:-}" ]; then
  SOURCE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  [ -x "$SOURCE" ] || { echo "no collector at $2" >&2; exit 1; }
  echo "==> Using $SOURCE"
elif [ -x "$ROOT/MacOS/switchboardd" ]; then
  # Inside Switchboard.app: Contents/Resources/install-collector.sh beside Contents/MacOS.
  SOURCE="$ROOT/MacOS/switchboardd"
  echo "==> Using the collector in $(cd "$ROOT/.." && pwd)"
else
  # Build as the person who ran sudo, so the build directory does not end up owned by root.
  BUILDER="${SUDO_USER:-root}"
  echo "==> Building the collector (as $BUILDER)"
  sudo -u "$BUILDER" swift build --package-path "$ROOT" -c release --product switchboardd
  SOURCE="$(sudo -u "$BUILDER" swift build --package-path "$ROOT" -c release --show-bin-path)/switchboardd"
  [ -x "$SOURCE" ] || { echo "build did not produce $SOURCE" >&2; exit 1; }
fi

for label in "$OLD_LABEL" "$LABEL"; do
  if launchctl print "system/$label" >/dev/null 2>&1; then
    echo "==> Stopping the running collector ($label)"
    launchctl bootout "system/$label" || true
  fi
done
rm -f "/Library/LaunchDaemons/$OLD_LABEL.plist"

echo "==> Installing $BINARY"
mkdir -p /usr/local/libexec
install -o root -g wheel -m 755 "$SOURCE" "$BINARY"

echo "==> Writing $PLIST"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BINARY</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>StandardOutPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "==> Starting"
# The old collector's socket may linger for a moment after it stops.
rm -f "$SOCKET"
launchctl bootstrap system "$PLIST"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$SOCKET" ] && break
  sleep 0.3
done
if [ -S "$SOCKET" ]; then
  echo "    Log: $LOG"
  echo "==> Running. Switchboard switches to Full mode within a couple of seconds."
else
  echo "The service was installed but its socket has not appeared. See $LOG" >&2
  exit 1
fi
