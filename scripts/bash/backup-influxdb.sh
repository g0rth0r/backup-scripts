#!/bin/bash
set -euo pipefail

TOKEN_FILE="/etc/backup-sync/influxdb-operator.token"
BASE="/data/tgi-stack/backups"
DATE=$(date +%F)
DEST="$BASE/influxdb-$DATE"
CONTAINER_TMP="/tmp/zanzibar-influx-backup-$$"

mkdir -p "$BASE"
STAGING=$(mktemp -d "$BASE/.influxdb-staging.XXXXXX")

cleanup() {
    docker exec influxdb rm -rf "$CONTAINER_TMP" \
        >/dev/null 2>&1 || true
    rm -rf -- "$STAGING"
}
trap cleanup EXIT

# Validate required files and compressed streams.
verify_snapshot() {
    local dir="$1"
    local pattern

    [[ -d "$dir" ]] || return 1

    for pattern in '*.manifest' '*.bolt.gz' '*.sqlite.gz'; do
        if [[ -z $(find "$dir" -maxdepth 1 -type f \
            -name "$pattern" -size +0c -print -quit) ]]; then
            echo "ERROR: Missing or empty $pattern in $dir" >&2
            return 1
        fi
    done

    if ! find "$dir" -maxdepth 1 -type f \
        -name '*.gz' -exec gzip -t -- {} +; then
        echo "ERROR: Corrupt compressed snapshot: $dir" >&2
        return 1
    fi
}

# Preserve existing snapshots; reject incomplete or corrupt ones.
if [[ -e "$DEST" || -L "$DEST" ]]; then
    if verify_snapshot "$DEST"; then
        echo "Verified InfluxDB snapshot already exists: $DEST"
        exit 0
    fi
    echo "ERROR: Existing snapshot invalid; refusing to skip" >&2
    exit 1
fi

echo "Starting InfluxDB native backup"

# Pass the token via stdin, not command-line arguments.
docker exec -i influxdb sh -c '
    INFLUX_TOKEN=$(cat)
    export INFLUX_TOKEN
    SSL_CERT_FILE=/tls/roland-root-ca.crt \
      influx backup \
      --host https://influxdb.zanzibar.home.arpa:8086 \
      "$1"
' sh "$CONTAINER_TMP" < "$TOKEN_FILE"

docker cp "influxdb:$CONTAINER_TMP/." "$STAGING/"

# Verify before publishing the completed snapshot.
verify_snapshot "$STAGING"

mv "$STAGING" "$DEST"

echo "InfluxDB backup complete: $DEST"
du -sh "$DEST"
