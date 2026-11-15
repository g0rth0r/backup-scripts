#!/bin/bash
set -euo pipefail

# Explicit full backup; scheduled runs remain incremental.
case "${1:-}" in
    "") MODE=incremental ;;
    --full) MODE=full ;;
    *) echo "Usage: $0 [--full]" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { echo "Too many arguments" >&2; exit 2; }

SNAPSHOT=/var/lib/portainer-backup.snar

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
[[ -s "$SNAPSHOT" ]] || {
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

# Restart stopped containers and remove temporary files on every exit.
full_cleanup() {
    local rc=$?
    local container

    trap - EXIT

    for container in "${stopped_containers[@]}"; do
        if docker start "$container" >> "$LOG" 2>&1; then
            echo "Restarted container: $container" >> "$LOG"
        else
            echo "CRITICAL: Failed to restart $container" >&2
            rc=1
        fi
    done

    if [[ -n "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    if [[ -n "$TMP_ARCHIVE" ]]; then
        rm -f -- "$TMP_ARCHIVE"
    fi

    exit "$rc"
}

# Back Up Data
if [[ "$MODE" == full ]]; then
    # A reset must not establish a baseline with failed DB exports.
    if (( backup_status != 0 )); then
        echo "ERROR: Refusing full reset: application helper failed" >&2
        exit 1
    fi

    OLD_SNAPSHOT="${SNAPSHOT}.pre-full-${DATE}"
    if [[ -e "$OLD_SNAPSHOT" || -L "$OLD_SNAPSHOT" ]]; then
        echo "ERROR: Previous snapshot backup already exists" >&2
        exit 1
    fi

    # Install recovery handlers before stopping any containers.
    TMP_DIR=""
    TMP_ARCHIVE=""
    stopped_containers=()

    trap full_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    TMP_DIR=$(mktemp -d /var/lib/.portainer-full.XXXXXXXX)
    TMP_ARCHIVE=$(mktemp "$DEST/.portainer-full.XXXXXXXX.tar.gz")
    NEW_SNAPSHOT="$TMP_DIR/snapshot.snar"

    # Do not change the original state of already-stopped containers.
    for container in plex sonarr tautulli; do
        if [[ $(docker inspect -f '{{.State.Running}}' "$container") != true ]]; then
            echo "ERROR: Required container not running: $container" >&2
            exit 1
        fi
    done

    for container in plex sonarr tautulli; do
        stopped_containers+=("$container")
        if ! docker stop --time 30 "$container" >> "$LOG" 2>&1; then
            echo "ERROR: Failed to stop $container" >&2
            exit 1
        fi
        echo "Stopped container: $container" >> "$LOG"
    done

    tar --listed-incremental="$NEW_SNAPSHOT" \
        --exclude-from="$EXCLUDES" \
        -czf "$TMP_ARCHIVE" "$SRC" \
        >> "$LOG" 2>&1

    # Restore services before publishing a successful full backup.
    restart_failed=0
    for container in "${stopped_containers[@]}"; do
        if docker start "$container" >> "$LOG" 2>&1; then
            echo "Restarted container: $container" >> "$LOG"
        else
            echo "ERROR: Failed to restart $container" >&2
            restart_failed=1
        fi
    done

    # Keep failed restarts in the EXIT handler for another attempt.
    if (( restart_failed != 0 )); then
        echo "ERROR: Full archive not published; service recovery failed" >&2
        exit 1
    fi
    stopped_containers=()

    # Preserve the old chain's snapshot before activation.
    cp -a -- "$SNAPSHOT" "$OLD_SNAPSHOT"

    # Publish the archive, then activate its snapshot metadata.
    mv -- "$TMP_ARCHIVE" "$ARCHIVE"
    if ! mv -- "$NEW_SNAPSHOT" "$SNAPSHOT"; then
        echo "CRITICAL: Full archive published but snapshot activation failed" >&2
        echo "Restore snapshot from: $OLD_SNAPSHOT" >&2
        exit 1
    fi

    echo "$(date): New full backup activated" >> "$LOG"
else
    tar --listed-incremental="$SNAPSHOT" \
        --exclude-from="$EXCLUDES" \
        -czf "$ARCHIVE" "$SRC" \
        >> "$LOG" 2>&1
fi

echo "$(date): Portainer archive creation complete" >> "$LOG"

if (( backup_status != 0 )); then
    echo "ERROR: One or more application backup helpers failed" \
        | tee -a "$LOG" >&2
fi

exit "$backup_status"
