#!/bin/bash
# Downloads the free DB-IP Lite databases that give Switchboard countries, cities, and
# network owners: about 130 MB from download.db-ip.com. Nothing else fetches them.
#
#   scripts/fetch-geoip.sh
#
# A copy travels inside Switchboard.app as fetch-geoip.sh; the app's Download Location
# Data button (Settings ▸ Location) runs it and reloads the databases afterwards. Run from
# here, restart Switchboard to use them.
#
# Files go to ~/Library/Application Support/Switchboard/GeoIP. DB-IP publishes new ones a
# day or two into each month; until this month's appear, last month's are used.
#
# The data is "IP Geolocation by DB-IP" (https://db-ip.com), licensed CC BY 4.0. If you
# publish anything derived from it, that attribution is required.

set -euo pipefail

DIR="$HOME/Library/Application Support/Switchboard/GeoIP"
mkdir -p "$DIR"

# A progress bar in a terminal; quiet when the app runs this.
if [ -t 2 ]; then PROGRESS=(--progress-bar); else PROGRESS=(--silent --show-error); fi

fetch() { # kind month
  local name="dbip-$1-lite-$2.mmdb"
  echo "==> https://download.db-ip.com/free/$name.gz"
  if curl --fail --location "${PROGRESS[@]}" --output "$DIR/$name.gz" "https://download.db-ip.com/free/$name.gz"; then
    gunzip --force "$DIR/$name.gz"
    # Keep only the newest of each kind.
    find "$DIR" -name "dbip-$1-lite-*.mmdb" ! -name "$name" -delete
    return 0
  fi
  rm -f "$DIR/$name.gz"
  return 1
}

THIS_MONTH="$(date +%Y-%m)"
LAST_MONTH="$(date -v-1m +%Y-%m)"
for kind in city asn; do
  if ! fetch "$kind" "$THIS_MONTH" && ! fetch "$kind" "$LAST_MONTH"; then
    echo "Could not download the $kind database for $THIS_MONTH or $LAST_MONTH from db-ip.com." >&2
    exit 1
  fi
done

ls -lh "$DIR"
echo "==> Downloaded the location databases to $DIR"
