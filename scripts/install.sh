#!/bin/bash
# Installs the Switchboard collector as a system service.
#
#   sudo scripts/install.sh
#
# What it does, and nothing else:
#   1. builds switchboardd if it is not built (as you, not as root)
#   2. copies it to /usr/local/libexec/switchboardd, owned by root
#   3. writes /Library/LaunchDaemons/local.switchboard.collector.plist
#   4. starts it, and has launchd keep it running
#
# scripts/uninstall.sh reverses every step.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This installs a system service, so it needs sudo:  sudo scripts/install.sh" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="local.switchboard.collector"
BINARY="/usr/local/libexec/switchboardd"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG="/var/log/switchboardd.log"

# Build as the person who ran sudo, so the build directory does not end up owned by root.
BUILDER="${SUDO_USER:-root}"
echo "==> Building the collector (as $BUILDER)"
sudo -u "$BUILDER" swift build --package-path "$ROOT" -c release --product switchboardd
SOURCE="$(sudo -u "$BUILDER" swift build --package-path "$ROOT" -c release --show-bin-path)/switchboardd"
[ -x "$SOURCE" ] || { echo "build did not produce $SOURCE" >&2; exit 1; }

echo "==> Installing $BINARY"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "system/$LABEL" || true
fi
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
launchctl bootstrap system "$PLIST"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S /var/run/switchboard.sock ] && break
  sleep 0.3
done
if [ -S /var/run/switchboard.sock ]; then
  echo "==> Running. The app will switch to Full mode within a couple of seconds."
  echo "    Log: $LOG      Remove with: sudo scripts/uninstall.sh"
else
  echo "The service was installed but its socket has not appeared. See $LOG" >&2
  exit 1
fi
