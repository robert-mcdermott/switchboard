#!/bin/bash
# Removes everything scripts/install.sh put in place, including a collector installed by
# a build before 0.1.0.
#
#   sudo scripts/uninstall.sh
#
# A copy travels inside Switchboard.app as uninstall-collector.sh; the app's Remove
# Collector button runs it.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This removes a system service, so it needs sudo:  sudo $0" >&2
  exit 1
fi

for label in io.github.robert-mcdermott.switchboard.collector local.switchboard.collector; do
  if launchctl print "system/$label" >/dev/null 2>&1; then
    echo "==> Stopping the collector ($label)"
    launchctl bootout "system/$label" || true
  fi
  if [ -e "/Library/LaunchDaemons/$label.plist" ]; then
    echo "==> Removing /Library/LaunchDaemons/$label.plist"
    rm -f "/Library/LaunchDaemons/$label.plist"
  fi
done

for path in /usr/local/libexec/switchboardd /var/run/switchboard.sock /var/log/switchboardd.log; do
  if [ -e "$path" ] || [ -S "$path" ]; then
    echo "==> Removing $path"
    rm -f "$path"
  fi
done

echo "==> Removed. Nothing of the collector remains; Switchboard carries on in Standalone mode."
