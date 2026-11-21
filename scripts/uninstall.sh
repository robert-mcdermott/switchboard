#!/bin/bash
# Removes everything scripts/install.sh put in place.
#
#   sudo scripts/uninstall.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This removes a system service, so it needs sudo:  sudo scripts/uninstall.sh" >&2
  exit 1
fi

LABEL="local.switchboard.collector"

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "==> Stopping the collector"
  launchctl bootout "system/$LABEL" || true
fi

for path in "/Library/LaunchDaemons/$LABEL.plist" /usr/local/libexec/switchboardd /var/run/switchboard.sock /var/log/switchboardd.log; do
  if [ -e "$path" ] || [ -S "$path" ]; then
    echo "==> Removing $path"
    rm -f "$path"
  fi
done

echo "==> Done. Nothing of the collector remains; the app carries on in Standalone mode."
