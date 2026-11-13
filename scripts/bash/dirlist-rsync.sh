#!/usr/bin/env bash
# Sync selected directories from SOURCE -> DEST using a list file of relative paths.
# Logs per-folder summaries and full rsync stats, suitable for systemd timers.

set -u  # (not set -e, we want to keep going on per-folder errors)

usage() {
  cat >&2 <<'EOF'
Usage:
  dirlist-rsync.sh [-n] [--delete] [--bwlimit KBps] SOURCE DEST DIR_LIST

  -n             Dry run (no changes)
  --delete       Mirror semantics (delete at DEST if removed at SOURCE)
  --bwlimit N    Throttle bandwidth (KB/s). Example: 20000 (~20 MB/s)

Notes:
  * DIR_LIST must contain RELATIVE paths (e.g., "audio/projects"), one per line.
  * Lines starting with # or blank lines are ignored.
  * We use rsync --relative with an explicit "./" anchor so paths are recreated under DEST.
  * A per-run log is written in DEST/.logs/
EOF
  exit 1
}

DRYRUN=() ; DELETE=() ; BWLIMIT=()

# ---- parse flags ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -n) DRYRUN=(-n); shift ;;
    --delete) DELETE=(--delete-delay); shift ;;
    --bwlimit) BWLIMIT=(--bwlimit "$2"); shift 2 ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done

[[ $# -eq 3 ]] || usage
SOURCE="$1"
DEST="$2"
DIR_LIST="$3"
SRC_LABEL="$(basename "$(dirname "$SOURCE")")"

# ---- validate inputs --------------------------------------------------------
[[ -d "$SOURCE" ]]   || { echo "ERROR: SOURCE not found: $SOURCE" >&2; exit 2; }
[[ -d "$DEST" ]]     || { echo "ERROR: DEST not found: $DEST" >&2; exit 2; }
[[ -f "$DIR_LIST" ]] || { echo "ERROR: DIR_LIST not found: $DIR_LIST" >&2; exit 2; }

# ---- logging setup ----------------------------------------------------------
STAMP="$(date +%F_%H-%M-%S)"
LOGDIR="/mnt/backup8/logs"
mkdir -p "$LOGDIR"
RUN_LOG="$LOGDIR/rsync_${SRC_LABEL}_$STAMP.log"
SUMMARY_CSV="$LOGDIR/rsync_summary.csv"   # cumulative summaries

echo "=== dirlist-rsync run @ $STAMP ==="            | tee -a "$RUN_LOG"
echo "SOURCE: $SOURCE"                                | tee -a "$RUN_LOG"
echo "DEST:   $DEST"                                  | tee -a "$RUN_LOG"
echo "LIST:   $DIR_LIST"                              | tee -a "$RUN_LOG"
echo "FLAGS:  ${DRYRUN[*]} ${DELETE[*]} ${BWLIMIT[*]}"| tee -a "$RUN_LOG"
echo "----------------------------------------------------------------"        | tee -a "$RUN_LOG"

# optional: nice/ionice to be gentle on system
NICE_PREFIX=(ionice -c2 -n7 nice -n 19)

# counters
total_ok=0
total_changed=0
total_nochange=0
total_err=0

# ensure DEST has a partial cache to resume large files safely
mkdir -p "$DEST/.rsync-partial"

# ---- process each line in list ---------------------------------------------
while IFS= read -r raw || [[ -n "$raw" ]]; do
  # trim whitespace
  line="${raw#"${raw%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  # skip blanks and comments
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  src_path="$SOURCE/./$line"   # the "./" anchor is the magic for --relative
  echo -e "\n>>> Syncing: $line" | tee -a "$RUN_LOG"

  # temp file to capture rsync output/stats for this folder
  tmp="$(mktemp)"
  # shellcheck disable=SC2068
  if "${NICE_PREFIX[@]}" rsync -aAXH \
        --relative --protect-args --numeric-ids --one-file-system \
        --human-readable --info=stats --itemize-changes \
        --out-format='%i|%l|%n' \
        --partial --partial-dir="$DEST/.rsync-partial" \
        "${DRYRUN[@]}" "${DELETE[@]}" "${BWLIMIT[@]}" \
        "$src_path" "$DEST" >"$tmp" 2>&1
  then
    # parse basic stats
    # %i starts with > or c when data was written; %l is byte length
    xfr=$(grep -E '^(>|\c).*?\|' "$tmp" | wc -l | tr -d ' ')
    bytes=$(awk -F'|' '/^(>|\c)/ {sum += $2} END {print sum+0}' "$tmp")
    #xfr=$(grep -Eo 'Number of regular files transferred: [0-9]+' "$tmp" | awk '{print $6+0}' | tail -n1)
    #bytes=$(grep -Eo 'Total transferred file size: [0-9,]+' "$tmp" | awk '{print $5}' | tr -d ',' | tail -n1)
    [[ -z "$xfr" ]] && xfr=0
    [[ -z "$bytes" ]] && bytes=0

    if [[ "$xfr" -gt 0 || "$bytes" -gt 0 ]]; then
      echo "RESULT: CHANGED (files=$xfr, bytes=$bytes)" | tee -a "$RUN_LOG"
      echo "$STAMP,$SRC_LABEL,$line,CHANGED,$xfr,$bytes" >> "$SUMMARY_CSV"
      ((total_changed++))
    else
      echo "RESULT: NOCHANGE" | tee -a "$RUN_LOG"
      echo "$STAMP,$SRC_LABEL,$line,NOCHANGE,0,0"        >> "$SUMMARY_CSV"
      ((total_nochange++))
    fi
    ((total_ok++))
  else
    rc=$?
    echo "RESULT: ERROR (rsync exit=$rc). See details below:" | tee -a "$RUN_LOG"
    echo "---- rsync output (start) ----"                      | tee -a "$RUN_LOG"
    sed -e 's/^[ \t]*//' "$tmp"                               | tee -a "$RUN_LOG"
    echo "---- rsync output (end) ----"                        | tee -a "$RUN_LOG"
    echo "$STAMP,$SRC_LABEL,$line,ERROR,$rc,0"         >> "$SUMMARY_CSV"
    ((total_err++))
  fi

  cat "$tmp" >> "$RUN_LOG"
  rm -f "$tmp"
done < "$DIR_LIST"

echo -e "\n=== Summary ==="                 | tee -a "$RUN_LOG"
echo "OK: $total_ok  CHANGED: $total_changed  NOCHANGE: $total_nochange  ERR: $total_err" | tee -a "$RUN_LOG"
gzip -f "$RUN_LOG"
echo "Log: $RUN_LOG"
echo "CSV: $SUMMARY_CSV"

if (( total_err > 0 )); then
  echo "ERROR: $total_err directory backup(s) failed" >&2
  exit 1
fi

exit 0
