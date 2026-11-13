#!/bin/bash
set -euo pipefail

LOCK=/run/backup8.lock   # same lock file!
exec 9>"$LOCK"
flock -n 9 || { echo "ERROR: Backup lock already held" >&2; exit 1; }

DATE=$(date +%F)
SRC="/data"
DEST="/mnt/backup8/sources/portainer"
EXCLUDES="/etc/docker-exclude.txt"
LOG="/mnt/backup8/logs/portainer-backup.log"

# Verify the actual backup filesystem, not the automount placeholder.
[[ -d /mnt/backup8/. ]] || {
    echo "ERROR: Backup mount unavailable" >&2
    exit 1
}

actual_uuid=$(findmnt -rn -M /mnt/backup8 -t ext4 -o UUID) || {
    echo "ERROR: Backup filesystem not mounted" >&2
    exit 1
}

[[ "$actual_uuid" == "82d31520-ad35-40da-b7a2-a85ad0e5d650" ]] || {
    echo "ERROR: Wrong backup filesystem" >&2
    exit 1
}

[[ -d "$SRC" && -f "$EXCLUDES" ]] || {
    echo "ERROR: Backup source or exclusions missing" >&2
    exit 1
}

# Never silently reset an existing incremental chain.
[[ -s /var/lib/portainer-backup.snar ]] || {
    echo "ERROR: Incremental snapshot state missing or empty" >&2
    exit 1
}

ARCHIVE="$DEST/portainer-${DATE}.tar.gz"

# Refuse overwrites, including dangling symbolic links.
if [[ -e "$ARCHIVE" || -L "$ARCHIVE" ]]; then
    echo "ERROR: Archive already exists: $ARCHIVE" >&2
    exit 1
fi

mkdir -p "$DEST"

# Record helper failures but continue creating the main archive.
backup_status=0

# Create a consistent InfluxDB snapshot before archiving /data.
if /usr/local/bin/backup-influxdb.sh >> "$LOG" 2>&1; then
    echo "$(date): InfluxDB backup successful" >> "$LOG"
else
    echo "$(date): WARNING: InfluxDB backup failed; continuing with /data backup" \
        | tee -a "$LOG" >&2
    backup_status=1
fi

# Back up RomM's MariaDB before archiving /data.
if /usr/local/bin/backup-romm.sh >> "$LOG" 2>&1; then
    echo "$(date): RomM backup successful" >> "$LOG"
else
    echo "$(date): WARNING: RomM backup failed; continuing with /data backup" \
        | tee -a "$LOG" >&2
    backup_status=1
fi

# Back up Portainer's persistent volume before archiving /data.
if /usr/local/bin/backup-portainer.sh >> "$LOG" 2>&1; then
    echo "$(date): Portainer volume backup successful" >> "$LOG"
else
    echo "$(date): WARNING: Portainer volume backup failed; continuing with /data backup" \
        | tee -a "$LOG" >&2
    backup_status=1
fi

# Back up Grafana's SQLite database before archiving /data.
if /usr/local/bin/backup-grafana.sh >> "$LOG" 2>&1; then
    echo "$(date): Grafana backup successful" >> "$LOG"
else
    echo "$(date): WARNING: Grafana backup failed; continuing with /data backup" \
        | tee -a "$LOG" >&2
    backup_status=1
fi

# Back Up Data
tar --listed-incremental=/var/lib/portainer-backup.snar \
    --exclude-from="$EXCLUDES" \
    -czf "$ARCHIVE" "$SRC" \
    >> "$LOG" 2>&1

echo "$(date): Portainer archive creation complete" >> "$LOG"

if (( backup_status != 0 )); then
    echo "ERROR: One or more application backup helpers failed" \
        | tee -a "$LOG" >&2
fi

exit "$backup_status"
