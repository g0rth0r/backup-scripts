#!/usr/bin/env python3
"""Expand a one-level backup directory list safely."""

import sys
from pathlib import Path

def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)

def validate_path(value):
    p = Path(value)

    if (
        p.is_absolute()
        or not value
        or "\\" in value
        or any(part in (".", "..", "") for part in value.split("/"))
        or any(c in value for c in "*?[]")
    ):
        fail(f"Unsafe backup path: {value!r}")

def expand(filename, allow_include=True):
    try:
        lines = filename.read_text().splitlines()
    except OSError as exc:
        fail(f"Cannot read {filename}: {exc}")

    for raw in lines:
        line = raw.strip()

        if not line or line.startswith("#"):
            continue

        if line.startswith("!"):
            if not allow_include:
                fail("Nested includes are not supported")

            if line != "!include offsite-backup-list.txt":
                fail(f"Unsupported directive: {line}")

            included = filename.parent / "offsite-backup-list.txt"
            yield from expand(included, False)
            continue

        validate_path(line)
        yield line

def main():
    if len(sys.argv) != 2:
        fail("Usage: expand-backup-list.py LIST_FILE")

    filename = Path(sys.argv[1])
    seen = set()

    # Validate the entire list before printing anything.
    entries = []
    for entry in expand(filename):
        if entry not in seen:
            seen.add(entry)
            entries.append(entry)

    for entry in entries:
        print(entry)

if __name__ == "__main__":
    main()
