#!/usr/bin/env bash
# Zanzibar: two-source Critical offsite backup with CSV reporting.
set -euo pipefail
umask 077

case "${1:-}" in
  --help|-h)
    printf 'Usage: sudo %s [--preview|--dry-run]\n' "${0##*/}"
    printf 'Preview: metadata-only scan, local, no cloud login or file hashing.\n'
    printf 'Dry-run: Restic exact backup simulation (can read/hash file contents).\n'
    printf 'Normal: encrypted backup to configured Restic repository.\n'
    exit 0 ;;
  --dry-run|--preview|"") ;;
  *) echo 'ERROR: Unsupported argument (try --help)' >&2; exit 2 ;;
esac
if (( EUID != 0 )); then echo 'ERROR: Run as root' >&2; exit 2; fi
# Preview is read-only and does not require or acquire Restic repository credentials.
# Keep exclusive lock for actual backup and Restic dry-run only.
if [[ "${1:-}" != "--preview" ]]; then
  exec 9>/run/lock/offsite-restic.lock
  flock -n 9 || { echo 'ERROR: Another offsite run is active' >&2; exit 1; }
fi

# Credentials must be a root-readable local file; never echoed to reports.
if [[ "${1:-}" != "--preview" ]]; then
  set -a
  # shellcheck source=/dev/null
  source /etc/restic/zanzibar.env
  set +a
  export RESTIC_PASSWORD_FILE=/etc/restic/zanzibar-password
  [[ -r "$RESTIC_PASSWORD_FILE" ]] || { echo 'ERROR: Restic password file missing' >&2; exit 1; }
  : "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY missing}"
  : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID missing}"
  : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY missing}"
fi

python3 - "${1:-}" <<'PY'
import csv
import datetime as dt
import fnmatch
import functools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

MODE = "preview" if sys.argv[1] == "--preview" else "dry-run" if sys.argv[1] == "--dry-run" else "backup"
ROOTS = {"storage": Path("/mnt/storage/root"), "beta": Path("/mnt/beta/root")}
SOURCE_MOUNTS = {"storage": Path("/mnt/storage"), "beta": Path("/mnt/beta")}
SELECTION = Path("/etc/backup-sync/offsite-backup-list.txt")
EXCLUDES = Path("/etc/backup-sync/offsite-exclude-list.txt")
REPORTS = Path("/var/log/offsite-restic")
RESTIC = shutil.which("restic")
HEADER = ["timestamp", "source", "path", "result", "files", "bytes", "mode",
          "snapshot_id", "uploaded_bytes", "excluded_events", "exit_code"]
START = dt.datetime.now().astimezone()
STAMP = START.strftime("%Y-%m-%d_%H-%M-%S")


def fail(message):
    raise RuntimeError(message)


def read_selected():
    if not SELECTION.is_file():
        fail(f"Missing selection file: {SELECTION}")
    result = []
    for number, raw in enumerate(SELECTION.read_text().splitlines(), 1):
        item = raw.strip()
        if not item or item.startswith("#"):
            continue
        if (item.startswith("/") or "\\" in item or any(p in (".", "..", "") for p in item.split("/"))
                or item.startswith("!") or any(c in item for c in "*?[]") or "\x00" in item):
            fail(f"Unsafe selection entry at line {number}: {item!r}")
        if item not in result:
            result.append(item)
    if not result:
        fail("Empty Critical selection; refusing to back up nothing")
    return result


def ensure_safe_root_path(root, rel):
    candidate = root
    for segment in rel.split("/"):
        candidate = candidate / segment
        if candidate.is_symlink():
            fail(f"Selected directory is a symlink: {candidate}")
    if not candidate.is_dir():
        fail(f"Missing selected directory: {candidate}")
    return candidate


def preflight():
    if MODE != "preview" and RESTIC is None:
        fail("restic executable missing")
    if not EXCLUDES.is_file():
        fail(f"Missing exclude file: {EXCLUDES}")
    for label, mount in SOURCE_MOUNTS.items():
        if not mount.is_mount():
            fail(f"Required source disk not mounted: {mount} ({label})")
    selected = read_selected()
    for root in ROOTS.values():
        if root.is_symlink() or not root.is_dir():
            fail(f"Invalid source root: {root}")
        for rel in selected:
            ensure_safe_root_path(root, rel)
    # Restic handles patterns for backup/dry-run; preview uses a documented safe subset.
    return selected


def atomic_csv(path, rows, header=HEADER):
    fd, tmp = tempfile.mkstemp(prefix=".offsite-", suffix=".csv", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=header)
            writer.writeheader()
            writer.writerows(rows)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)



# Fast metadata-only estimate. Matches a safe and deliberately restricted subset
# of Restic's glob exclusions: basename globs, path globs, ** path components,
# and anchored absolute path globs. Reject unsupported syntax rather than
# confidently reporting misleading selected bytes.
def parse_preview_patterns():
    patterns = []
    for n, raw in enumerate(EXCLUDES.read_text(encoding="utf-8").splitlines(), 1):
        p = raw.strip()
        if not p or p.startswith("#"):
            continue
        if ("\\" in p or "!" in p or "$" in p
                or "\x00" in p or "//" in p or p.endswith("/")):
            fail(f"Unsupported preview exclusion at line {n}: {p!r}; use --dry-run")
        parts = p.lstrip("/").split("/")
        if any(not c or ("**" in c and c != "**") or c in (".", "..") for c in parts):
            fail(f"Unsupported preview exclusion at line {n}: {p!r}; use --dry-run")
        # fnmatch supports ?, bracket ranges; no environment variable expansion.
        patterns.append((p.startswith("/"), tuple(parts), p))
    return patterns


def match_components(pattern, parts):
    @functools.lru_cache(None)
    def match(i, j):
        if i == len(pattern):
            return j == len(parts)
        if pattern[i] == "**":
            return match(i + 1, j) or (j < len(parts) and match(i, j + 1))
        return (j < len(parts) and fnmatch.fnmatchcase(parts[j], pattern[i])
                and match(i + 1, j + 1))
    return match(0, 0)


def is_excluded(path, patterns):
    parts = path.parts
    for anchored, pattern, _ in patterns:
        if anchored:
            if match_components(pattern, parts[1:]):
                return True
        elif any(match_components(pattern, parts[i:]) for i in range(len(parts))):
            return True
    return False


def preview_dir(directory, patterns):
    counts = dict(included_files=0, included_bytes=0, excluded_files=0,
                  excluded_bytes=0, symlinks=0, scan_errors=0)
    # Enumerate excluded trees too so excluded bytes are counted, but never read data.
    stack = [(directory, False)]
    while stack:
        current, excluded_parent = stack.pop()
        try:
            with os.scandir(current) as it:
                for entry in it:
                    path = Path(entry.path)
                    excluded = excluded_parent or is_excluded(path, patterns)
                    try:
                        if entry.is_symlink():
                            counts["symlinks"] += 1
                            continue  # Restic stores links; link target bytes are not read.
                        if entry.is_dir(follow_symlinks=False):
                            stack.append((path, excluded))
                        elif entry.is_file(follow_symlinks=False):
                            size = entry.stat(follow_symlinks=False).st_size
                            kind = "excluded" if excluded else "included"
                            counts[kind + "_files"] += 1
                            counts[kind + "_bytes"] += size
                        else:
                            # Unix special files aren't counted as logical data bytes.
                            continue
                    except OSError as ex:
                        counts["scan_errors"] += 1
                        print(f"ERROR: cannot stat {path}: {ex}", file=sys.stderr)
        except OSError as ex:
            counts["scan_errors"] += 1
            print(f"ERROR: cannot enumerate {current}: {ex}", file=sys.stderr)
    return counts


def preview_main():
    selected = preflight()
    patterns = parse_preview_patterns()
    REPORTS.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(REPORTS, 0o700)
    rows = []
    details = []
    bad = False
    totals = dict(included_files=0, included_bytes=0, excluded_files=0,
                  excluded_bytes=0, symlinks=0, scan_errors=0)
    print(f"=== OFFSITE METADATA PREVIEW {STAMP} ===", flush=True)
    print("LOCAL ONLY: no repository access, hashing, uploads or snapshots", flush=True)
    print(f"Selections: {len(selected)} paths per source", flush=True)
    for label, root in ROOTS.items():
        for rel in selected:
            stat = preview_dir(root / rel, patterns)
            for k in totals:
                totals[k] += stat[k]
            bad |= stat["scan_errors"] > 0
            details.append(dict(timestamp=STAMP, source=label, path=rel, **stat))
            rows.append(dict(timestamp=STAMP, source=label, path=rel,
                             result="ERROR" if stat["scan_errors"] else "PREVIEW",
                             files=stat["included_files"], bytes=stat["included_bytes"],
                             mode=MODE, snapshot_id="", uploaded_bytes="",
                             excluded_events=stat["excluded_files"],
                             exit_code=1 if stat["scan_errors"] else 0))
            print(f"{label:7} {rel:22} included={stat['included_files']} files / "
                  f"{stat['included_bytes'] / 1024**3:.2f} GiB; excluded="
                  f"{stat['excluded_files']} files / {stat['excluded_bytes'] / 1024**3:.2f} GiB; "
                  f"errors={stat['scan_errors']}", flush=True)
    run_csv = REPORTS / f"offsite_preview_{STAMP}.csv"
    atomic_csv(run_csv, rows)
    # Detailed manifest includes excluded logical bytes, which the original
    # Backup8-compatible CSV lacks. Both are written atomically.
    detail_path = REPORTS / f"offsite_preview_details_{STAMP}.csv"
    detail_header = ["timestamp", "source", "path", "included_files", "included_bytes",
                     "excluded_files", "excluded_bytes", "symlinks", "scan_errors"]
    atomic_csv(detail_path, details, header=detail_header)
    history = REPORTS / "offsite_summary.csv"
    historical = []
    if history.exists():
        with history.open(newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames != HEADER:
                fail(f"Existing history has incompatible header: {history}")
            historical = list(reader)
    atomic_csv(history, historical + rows)
    print(f"TOTAL INCLUDED: {totals['included_files']} files; "
          f"{totals['included_bytes'] / 1024**3:.2f} GiB logical", flush=True)
    print(f"TOTAL EXCLUDED: {totals['excluded_files']} files; "
          f"{totals['excluded_bytes'] / 1024**3:.2f} GiB logical", flush=True)
    print(f"SYMLINKS: {totals['symlinks']}; SCAN ERRORS: {totals['scan_errors']}", flush=True)
    print(f"Manifest: {run_csv}\nDetails: {detail_path}\nHistory: {history}", flush=True)
    print("RESULT: FAILED" if bad else "RESULT: METADATA PREVIEW ONLY", flush=True)
    print("NOTE: Logical bytes are not upload size; compression, dedup and history differ.", flush=True)
    print("NOTE: Preview exclusion matching is an approximation; use --dry-run to verify changes.", flush=True)
    return 1 if bad else 0


def main():
    if MODE == "preview":
        return preview_main()
    selected = preflight()
    REPORTS.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(REPORTS, 0o700)
    rows = []
    failed = False
    print(f"=== OFFSITE {MODE.upper()} {STAMP} ===", flush=True)
    print(f"Selections: {len(selected)} paths per source; reports: {REPORTS}", flush=True)
    for label, root in ROOTS.items():
        for rel in selected:
            directory = root / rel
            log = REPORTS / f"restic_{label}_{rel.replace('/', '-')}_{STAMP}.jsonl"
            cmd = [RESTIC, "backup", "--json", "--verbose=2", "--tag", "offsite-critical",
                   "--tag", f"source-{label}", "--exclude-file", str(EXCLUDES)]
            if MODE == "dry-run":
                cmd += ["--dry-run"]
            cmd += [str(directory)]
            summary = None
            excluded_events = 0
            rc = 1
            with log.open("w", encoding="utf-8") as f:
                os.chmod(log, 0o600)
                try:
                    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                               text=True, encoding="utf-8", errors="replace")
                    for line in process.stdout:
                        f.write(line)
                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if event.get("message_type") == "summary":
                            summary = event
                        elif event.get("message_type") == "excluded_item":
                            excluded_events += 1
                    rc = process.wait()
                except OSError as exc:
                    f.write(f"Runner failure: {exc}\n")
                    rc = 1
            successful = rc == 0 and summary is not None
            if not successful:
                failed = True
            changed = int((summary or {}).get("files_new", 0)) + int((summary or {}).get("files_changed", 0))
            result = "ERROR" if not successful else "PREVIEW" if MODE == "dry-run" else "CHANGED" if changed else "NOCHANGE"
            # Total processed files/bytes = selected logical content, not network transfer.
            row = {"timestamp": STAMP, "source": label, "path": rel, "result": result,
                   "files": (summary or {}).get("total_files_processed", ""),
                   "bytes": (summary or {}).get("total_bytes_processed", ""),
                   "mode": MODE,
                   "snapshot_id": (summary or {}).get("snapshot_id", "") if MODE == "backup" else "",
                   "uploaded_bytes": (summary or {}).get("data_added_packed", "") if MODE == "backup" else "",
                   "excluded_events": excluded_events, "exit_code": rc}
            rows.append(row)
            print(f"{label:7} {rel:22} {result:8} files={row['files']} bytes={row['bytes']} rc={rc}", flush=True)
            if not successful:
                print(f"ERROR: {label}/{rel} failed; see {log}", file=sys.stderr, flush=True)
                break
        if failed:
            break

    # A per-run manifest is always written, including failures; cumulative report is atomic.
    run_csv = REPORTS / f"offsite_{MODE}_{STAMP}.csv"
    atomic_csv(run_csv, rows)
    history = REPORTS / "offsite_summary.csv"
    historical = []
    if history.exists():
        with history.open(newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames != HEADER:
                fail(f"Existing history has incompatible header: {history}")
            historical = list(reader)
    atomic_csv(history, historical + rows)
    print(f"Manifest: {run_csv}\nHistory:  {history}", flush=True)
    print("RESULT: FAILED" if failed else f"RESULT: {'PREVIEW ONLY' if MODE == 'dry-run' else 'BACKUP COMPLETED'}", flush=True)
    return 1 if failed else 0


try:
    sys.exit(main())
except Exception as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PY
