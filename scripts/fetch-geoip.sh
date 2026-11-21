#!/bin/bash
# Downloads the free DB-IP Lite databases that give Switchboard countries, cities, and
# network owners. You run this; the app never fetches anything itself.
#
#   scripts/fetch-geoip.sh
#
# Files go to ~/Library/Application Support/Switchboard/GeoIP and are read the next time
# the app starts. Run it again any month to refresh them.
#
# The data is "IP Geolocation by DB-IP" (https://db-ip.com), licensed CC BY 4.0. If you
# publish anything derived from it, that attribution is required.

set -euo pipefail

DIR="$HOME/Library/Application Support/Switchboard/GeoIP"
MONTH="$(date +%Y-%m)"
mkdir -p "$DIR"

for kind in city asn; do
  name="dbip-$kind-lite-$MONTH.mmdb"
  url="https://download.db-ip.com/free/$name.gz"
  echo "==> $url"
  if ! curl --fail --location --progress-bar --output "$DIR/$name.gz" "$url"; then
    echo "    not available. DB-IP publishes each month's file a day or two into the month;" >&2
    echo "    if this is the start of a month, try again tomorrow." >&2
    rm -f "$DIR/$name.gz"
    exit 1
  fi
  gunzip --force "$DIR/$name.gz"
  # Keep only the newest of each kind.
  find "$DIR" -name "dbip-$kind-lite-*.mmdb" ! -name "$name" -delete
done

echo "==> Done. Databases in: $DIR"
ls -lh "$DIR"
echo "Restart Switchboard to use them. Check one with:  sbctl geo 8.8.8.8"
