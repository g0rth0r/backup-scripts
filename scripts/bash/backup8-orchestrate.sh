#!/usr/bin/env bash
set -euo pipefail
LOCK=/run/backup8.lock
exec 9>"$LOCK"; flock -n 9 || {
  echo "ERROR: Backup lock already held" >&2
  exit 1
}

# Confirm expected physical filesystems before any backup writes.
check_mount() {
  local path="$1" expected="$2" actual

  # Access the directory to trigger systemd automount if needed.
  [[ -d "$path/." ]] || {
    echo "ERROR: Mount path unavailable: $path" >&2
    return 1
  }

  actual=$(findmnt -rn -M "$path" -t ext4 -o UUID) || {
    echo "ERROR: Expected ext4 mount missing: $path" >&2
    return 1
  }

  [[ "$actual" == "$expected" ]] || {
    echo "ERROR: Unexpected filesystem at $path" >&2
    return 1
  }
}

check_mount /mnt/backup8 82d31520-ad35-40da-b7a2-a85ad0e5d650
check_mount /mnt/storage 07cb89ae-814c-4f08-a364-ccfd8cdee3a8
check_mount /mnt/beta b15a89c9-5863-4520-8e4c-9bbc291df7b8

# Paths
LIST_ALPHA=/etc/backup-sync/alpha-backup-list.txt

# 1) storage → backup
backup_status=0
if ! /usr/local/bin/dirlist-rsync.sh /mnt/storage/root /mnt/backup8/sources/nas-storage/latest "$LIST_ALPHA"; then
  echo "ERROR: Storage backup failed" >&2
  backup_status=1
fi

# 2) beta → backup
if ! /usr/local/bin/dirlist-rsync.sh /mnt/beta/root /mnt/backup8/sources/nas-beta/latest "$LIST_ALPHA"; then
  echo "ERROR: Beta backup failed" >&2
  backup_status=1
fi

exit "$backup_status"

# 3) dedupe across both (space saving)
#/usr/bin/fclones link \
#  /mnt/backup8/sources/nas-storage/latest \
#  /mnt/backup8/sources/nas-beta/latest \
#  --min-size 1k \
#  --prefer /mnt/backup8/sources/nas-storage/latest \
#  | tee -a /mnt/backup8/logs/fclones_$(date +%F).log
