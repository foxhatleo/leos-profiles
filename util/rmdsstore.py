#!/usr/bin/env python3
"""Remove Finder/Windows metadata files from an explicitly chosen tree.

The script is intentionally usable without the zsh profile.  It never follows
symlinks, will not descend into mounted filesystems below the chosen root, and
returns a non-zero status when the requested root is invalid or a deletion
fails.  Use --dry-run to inspect scope before deleting anything.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from dataclasses import dataclass


IGNORED_DIRS = {"CloudStorage"}
METADATA_FILES = {".DS_Store", "Thumbs.db", "desktop.ini"}
RECYCLE_BIN = "$RECYCLE.BIN"


@dataclass
class Result:
    removed: int = 0
    failures: int = 0
    skipped_mounts: int = 0


def _term_width() -> int:
    try:
        return os.get_terminal_size().columns
    except OSError:
        return 80


def _display_path(path: str, root: str) -> str:
    sanitized = re.sub(r"[^ a-zA-Z0-9!@#$%^&*()_+={}[\]|\\:;\"'<>,.?/\\~`-]", "?", path)
    sanitized_root = re.sub(r"[^ a-zA-Z0-9!@#$%^&*()_+={}[\]|\\:;\"'<>,.?/\\~`-]", "?", root)
    if sanitized.startswith(sanitized_root):
        return sanitized[len(sanitized_root) :].lstrip(os.sep) or "."
    return sanitized


def progress(path: str, root: str, prompt: str = "Scanning: {}...", newline: bool = False) -> None:
    width = _term_width()
    rendered = _display_path(path, root)
    overhead = len(prompt.format(""))
    allowed = max(0, width - overhead)
    line = prompt.format(rendered[:allowed])[:width]
    sys.stdout.write(line.ljust(width))
    sys.stdout.write("\n" if newline else "\r")
    sys.stdout.flush()


def remove_path(path: str, root: str, dry_run: bool, result: Result, is_dir: bool) -> None:
    verb = "Would remove" if dry_run else "Removing"
    progress(path, root, prompt=f"{verb} {{}}...", newline=True)
    if dry_run:
        result.removed += 1
        return
    try:
        if is_dir and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
        result.removed += 1
    except OSError as error:
        result.failures += 1
        progress(path, root, prompt=f"Could not remove ({{}}): {error}", newline=True)


def scan(root: str, dry_run: bool, purge_recycle_bins: bool = False) -> Result:
    root = os.path.abspath(os.path.normpath(root))
    if os.path.islink(root):
        raise ValueError(f"Scan root must not be a symbolic link: {root}")
    if not os.path.isdir(root):
        raise ValueError(f"Not a readable directory: {root}")

    result = Result()

    def walk_error(error: OSError) -> None:
        result.failures += 1
        failed_path = error.filename or root
        # The error text contains the path; escape braces so progress()'s
        # str.format template cannot choke on it.
        detail = str(error).replace("{", "{{").replace("}", "}}")
        progress(failed_path, root, prompt=f"Could not scan ({{}}): {detail}", newline=True)

    for current_root, dirs, files in os.walk(
        root, topdown=True, onerror=walk_error, followlinks=False
    ):
        progress(current_root, root)
        retained_dirs = []
        for name in dirs:
            candidate = os.path.join(current_root, name)
            if name.endswith(".duck") or name in IGNORED_DIRS:
                continue
            if os.path.ismount(candidate):
                result.skipped_mounts += 1
                progress(candidate, root, prompt="Skipping mounted filesystem {}...", newline=True)
                continue
            if name == RECYCLE_BIN:
                if purge_recycle_bins:
                    remove_path(candidate, root, dry_run, result, is_dir=True)
                continue
            retained_dirs.append(name)
        dirs[:] = retained_dirs

        for name in files:
            if name in METADATA_FILES:
                remove_path(os.path.join(current_root, name), root, dry_run, result, is_dir=False)
    return result


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="report files that would be removed")
    parser.add_argument(
        "--purge-recycle-bins",
        action="store_true",
        help="also remove directories named $RECYCLE.BIN and their contents",
    )
    parser.add_argument("root", help="directory tree to scan")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = os.path.abspath(args.root)
    print(f'Running rmdsstore on "{root}"{" (dry run)" if args.dry_run else ""}.', flush=True)
    try:
        result = scan(root, args.dry_run, args.purge_recycle_bins)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    print(f"\nFinished: {result.removed} item(s) {'would be ' if args.dry_run else ''}removed; "
          f"{result.skipped_mounts} mounted filesystem(s) skipped; {result.failures} failure(s).")
    return 1 if result.failures else 0


if __name__ == "__main__":
    sys.exit(main())
