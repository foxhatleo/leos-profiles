#!/usr/bin/env python3
"""Remove Finder/Windows metadata files from an explicitly chosen tree.

The script is intentionally usable without the zsh profile.  It never follows
symlinks, will not descend into mounted filesystems below the chosen root, and
returns a non-zero status when the requested root is invalid or a deletion
fails.  Directories that cannot be *entered* (e.g. macOS TCC/SIP-protected
paths, which stay unreadable even under sudo) are skipped rather than counted as
failures, so a clean sweep still exits 0; a metadata file that is found but
cannot be deleted still counts as a failure.  Use --dry-run to inspect scope
before deleting anything.
"""

from __future__ import annotations

import argparse
import errno
import os
import re
import shutil
import sys
from dataclasses import dataclass


METADATA_FILES = {".DS_Store", "Thumbs.db", "desktop.ini"}
RECYCLE_BIN = "$RECYCLE.BIN"
MACOS_DATA_ROOT = "/System/Volumes/Data"
MACOS_VOLUMES_ROOT = "/Volumes"


@dataclass
class Result:
    removed: int = 0
    failures: int = 0
    skipped_mounts: int = 0
    skipped_unreadable: int = 0

    def add(self, other: Result) -> None:
        self.removed += other.removed
        self.failures += other.failures
        self.skipped_mounts += other.skipped_mounts
        self.skipped_unreadable += other.skipped_unreadable


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
        # A metadata file we found but cannot delete (permission, immutable flag,
        # I/O) is a genuine failure the caller should see — unlike a directory we
        # could not even enter (handled in walk_error). Escape braces so a path
        # containing '{' or '}' cannot break progress()'s str.format template.
        result.failures += 1
        detail = str(error).replace("{", "{{").replace("}", "}}")
        progress(path, root, prompt=f"Could not remove ({{}}): {detail}", newline=True)


def _directory_key(path: str) -> tuple[int, int]:
    stat = os.stat(path, follow_symlinks=False)
    return stat.st_dev, stat.st_ino


def unique_roots(roots: list[str]) -> list[str]:
    """Return existing directory roots once, preserving their requested order."""
    unique = []
    seen: set[tuple[int, int]] = set()
    for root in roots:
        normalized = os.path.abspath(os.path.normpath(root))
        if os.path.islink(normalized) or not os.path.isdir(normalized):
            # Keep invalid roots so scan() can report the existing precise error.
            unique.append(normalized)
            continue
        try:
            key = _directory_key(normalized)
        except OSError:
            # Preserve a raced or inaccessible root for scan() to diagnose.
            unique.append(normalized)
            continue
        if key not in seen:
            seen.add(key)
            unique.append(normalized)
    return unique


def discover_default_roots(
    data_root: str = MACOS_DATA_ROOT, volumes_root: str = MACOS_VOLUMES_ROOT
) -> list[str]:
    """Find the writable macOS data volume and separately mounted volumes."""
    roots = []
    if os.path.isdir(data_root) and not os.path.islink(data_root):
        roots.append(data_root)

    entries = []
    if os.path.isdir(volumes_root):
        with os.scandir(volumes_root) as volume_entries:
            entries = sorted(volume_entries, key=lambda entry: entry.name)
    for entry in entries:
        if (
            entry.is_dir(follow_symlinks=False)
            and not entry.is_symlink()
            and os.path.ismount(entry.path)
        ):
            roots.append(entry.path)
    return unique_roots(roots)


def scan(root: str, dry_run: bool, purge_recycle_bins: bool = False) -> Result:
    root = os.path.abspath(os.path.normpath(root))
    if os.path.islink(root):
        raise ValueError(f"Scan root must not be a symbolic link: {root}")
    if not os.path.isdir(root):
        raise ValueError(f"Not a readable directory: {root}")

    result = Result()

    def walk_error(error: OSError) -> None:
        failed_path = error.filename or root
        # The error text contains the path; escape braces so progress()'s
        # str.format template cannot choke on it.
        detail = str(error).replace("{", "{{").replace("}", "}}")
        if getattr(error, "errno", None) in (errno.EACCES, errno.EPERM):
            # macOS TCC/SIP blocks traversal of protected trees (Mail, Photos,
            # ...) even under sudo. That is "nothing to clean here", not a
            # deletion failure, so a clean sweep still exits 0.
            result.skipped_unreadable += 1
            progress(failed_path, root, prompt=f"Skipping unreadable ({{}}): {detail}", newline=True)
            return
        result.failures += 1
        progress(failed_path, root, prompt=f"Could not scan ({{}}): {detail}", newline=True)

    for current_root, dirs, files in os.walk(
        root, topdown=True, onerror=walk_error, followlinks=False
    ):
        progress(current_root, root)
        retained_dirs = []
        for name in dirs:
            candidate = os.path.join(current_root, name)
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
    parser.add_argument(
        "root",
        nargs="*",
        help="directory tree(s) to scan; defaults to macOS data and mounted volumes",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        roots = unique_roots(args.root) if args.root else discover_default_roots()
    except OSError as error:
        print(f"ERROR: Could not discover mounted volumes: {error}", file=sys.stderr)
        return 2
    if not roots:
        print("ERROR: No macOS data or mounted-volume roots found.", file=sys.stderr)
        return 2

    result = Result()
    valid_roots = 0
    for root in roots:
        print(
            f'Running rmdsstore on "{root}"{" (dry run)" if args.dry_run else ""}.',
            flush=True,
        )
        try:
            result.add(scan(root, args.dry_run, args.purge_recycle_bins))
            valid_roots += 1
        except ValueError as error:
            result.failures += 1
            print(f"ERROR: {error}", file=sys.stderr)

    print(
        f"\nFinished: {result.removed} item(s) {'would be ' if args.dry_run else ''}removed; "
        f"{result.skipped_mounts} nested mounted filesystem(s) skipped; "
        f"{result.skipped_unreadable} unreadable path(s) skipped; "
        f"{result.failures} failure(s)."
    )
    if not valid_roots:
        return 2
    return 1 if result.failures else 0


if __name__ == "__main__":
    sys.exit(main())
