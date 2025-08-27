#!/usr/bin/env python3
import argparse
import os
from pathlib import Path

DEFAULT_BACKUP_LIST = "/etc/backup-sync/alpha-backup-list.txt"
DEFAULT_DISPOSABLE_LIST = "/etc/backup-sync/disposable-media.txt"

def load_list(p: Path):
    if not p.exists():
        return []
    lines = []
    for line in p.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        # normalize like a path (no leading slash, no trailing slash)
        s = s.strip("/ ")
        lines.append(s)
    return lines

def find_rel_under_nas_root(abs_path: Path, nas_root_name: str):
    parts = abs_path.resolve().parts
    try:
        idx = parts.index(nas_root_name)
    except ValueError:
        return None  # couldn't find the NAS root marker
    rel_parts = parts[idx+1:]
    return "/".join(rel_parts)

def match_rule(relpath: str, rules: list[str]):
    # Normalize
    relpath = relpath.strip("/")

    # A path matches a rule if it equals the rule OR is nested under it.
    # Use component-aware matching to avoid "videos/personalX" false positives.
    # Implement by checking relpath == rule OR relpath startswith(rule + "/")
    for rule in rules:
        r = rule.strip("/")
        if relpath == r or relpath.startswith(r + "/"):
            return rule
    return None

def main():
    ap = argparse.ArgumentParser(
        description="Check if a path will be backed up based on backup/disposable lists."
    )
    ap.add_argument(
        "path",
        nargs="?",
        default=".",
        help="Path to check (file or directory). Default: current directory."
    )
    ap.add_argument(
        "--backup-list",
        default=DEFAULT_BACKUP_LIST,
        help=f"Backup list file (default: {DEFAULT_BACKUP_LIST})"
    )
    ap.add_argument(
        "--disposable-list",
        default=DEFAULT_DISPOSABLE_LIST,
        help=f"Disposable list file (default: {DEFAULT_DISPOSABLE_LIST})"
    )
    ap.add_argument(
        "--nas-root-name",
        default=os.environ.get("NAS_ROOT_NAME", "root"),
        help="Name of the NAS root directory component to anchor relative paths (default: 'root' or $NAS_ROOT_NAME)"
    )
    args = ap.parse_args()

    target = Path(args.path).resolve()
    if not target.exists():
        print(f"ERROR: Path not found: {target}")
        raise SystemExit(2)

    # If a file is given, evaluate its parent directory
    if target.is_file():
        target = target.parent

    rel = find_rel_under_nas_root(target, args.nas_root_name)
    if rel is None:
        print(f"Path            : {target}")
        print(f"NAS root marker : '{args.nas_root_name}' not found in path")
        print("Verdict         : UNKNOWN (cannot determine NAS-relative path)")
        raise SystemExit(1)

    backup_rules = load_list(Path(args.backup_list))
    disposable_rules = load_list(Path(args.disposable_list))

    match_disposable = match_rule(rel, disposable_rules)
    match_backup = match_rule(rel, backup_rules)

    # Disposable wins if both match
    if match_disposable:
        verdict = "EXCLUDED (disposable)"
        matched = match_disposable
        matched_from = "disposable-media.txt"
    elif match_backup:
        verdict = "BACKED UP"
        matched = match_backup
        matched_from = "alpha-backup-list.txt"
    else:
        verdict = "NOT IN BACKUP LIST"
        matched = "-"
        matched_from = "-"

    print(f"Absolute path   : {target}")
    print(f"NAS relative    : {rel if rel else '/'}")
    print(f"Verdict         : {verdict}")
    print(f"Matched rule    : {matched}")
    print(f"Rule source     : {matched_from}")
    print(f"Lists used      : backup={args.backup_list} | disposable={args.disposable_list}")
    print(f"NAS root name   : {args.nas_root_name}")

if __name__ == "__main__":
    main()

