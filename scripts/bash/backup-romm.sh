#!/bin/bash
set -euo pipefail
umask 077

DEST="/data/romm/backups"
DATE=$(date +%F)
OUTPUT="$DEST/romm-$DATE.sql.gz"

mkdir -p "$DEST"

# Don't overwrite an existing successful backup.
if [[ -s "$OUTPUT" ]]; then
    echo "RomM backup already exists: $OUTPUT"
    exit 0
fi

TMP=$(mktemp "$DEST/.romm-XXXXXX.sql.gz")
trap 'rm -f "$TMP"' EXIT

echo "Starting RomM MariaDB backup"

docker exec romm-db sh -c '
    export MYSQL_PWD="$MARIADB_PASSWORD"
    exec mariadb-dump \
        -u "$MARIADB_USER" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        "$MARIADB_DATABASE"
' | gzip > "$TMP"

gzip -t "$TMP"
test -s "$TMP"

mv "$TMP" "$OUTPUT"

echo "RomM backup complete: $OUTPUT"
du -h "$OUTPUT"
