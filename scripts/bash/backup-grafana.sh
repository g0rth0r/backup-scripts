#!/bin/bash
set -euo pipefail
umask 077

DEST="/data/grafana/backups"
OUTPUT="$DEST/grafana-$(date +%F).db.gz"

install -d -m 700 "$DEST"

if [[ -s "$OUTPUT" ]]; then
    echo "Grafana backup already exists: $OUTPUT"
    exit 0
fi

TMP=$(mktemp "$DEST/.grafana-XXXXXXXX.db.gz")
trap 'rm -f -- "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import gzip
import os
import sqlite3
import sys
import tempfile

source = "/var/lib/docker/volumes/tgi-stack_grafana-storage/_data/grafana.db"
output = sys.argv[1]

with tempfile.TemporaryDirectory() as work:
    snapshot = os.path.join(work, "grafana.db")

    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as src:
        with sqlite3.connect(snapshot) as dst:
            src.backup(dst)
            result = dst.execute("PRAGMA integrity_check").fetchone()[0]
            if result != "ok":
                raise RuntimeError(f"SQLite integrity check failed: {result}")

    with open(snapshot, "rb") as f, gzip.open(output, "wb") as gz:
        while chunk := f.read(1024 * 1024):
            gz.write(chunk)

print("Grafana SQLite backup and integrity check successful")
PY

gzip -t "$TMP"
mv "$TMP" "$OUTPUT"

echo "Grafana backup complete: $OUTPUT"
du -h "$OUTPUT"
