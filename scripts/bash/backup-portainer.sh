#!/bin/bash
set -euo pipefail
umask 077

DEST="/data/portainer/backups"
OUTPUT="$DEST/portainer-$(date +%F).tar.gz"
VOLUME="/var/lib/docker/volumes/portainer_data/_data"

mkdir -p "$DEST"
chmod 700 "$DEST"

if [[ -s "$OUTPUT" ]]; then
    echo "Portainer backup already exists: $OUTPUT"
    exit 0
fi

TMP=$(mktemp "$DEST/.portainer-XXXXXXXX.tar.gz")
STOPPED=0

cleanup() {
    status=$?
    trap - EXIT

    if (( STOPPED )); then
        echo "Restarting Portainer"
        docker start portainer || status=1
    fi

    rm -f -- "$TMP"
    exit "$status"
}
trap cleanup EXIT

echo "Stopping Portainer"
docker stop portainer
STOPPED=1

echo "Creating Portainer archive"
tar -czf "$TMP" -C "$VOLUME" .

echo "Verifying archive"
tar -tzf "$TMP" >/dev/null

echo "Restarting Portainer"
docker start portainer
STOPPED=0

mv "$TMP" "$OUTPUT"

echo "Portainer backup complete: $OUTPUT"
du -h "$OUTPUT"
