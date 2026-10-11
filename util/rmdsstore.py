#!/usr/bin/env python3
"""Remove Finder/Windows metadata files from an explicitly chosen tree.

The script is intentionally usable without the zsh profile.  It never follows
symlinks, will not descend into mounted filesystems below the chosen root, and
returns a non-zero status when the requested root is invalid or a deletion
fails.  Every deletion is relative to a directory descriptor opened during the
walk without following links, so swapping a directory for a symlink while the
scan runs cannot redirect a deletion elsewhere.  Directories that cannot be
*entered* (e.g. macOS TCC/SIP-protected
paths, which stay unreadable even under sudo) are skipped rather than counted as
failures, so a clean sweep still exits 0; a metadata file that is found but
cannot be deleted still counts as a failure.  Use --dry-run to inspect scope
before deleting anything.
Linux mount boundaries include same-device bind mounts from /proc/self/mountinfo;
if that table cannot be read, scanning fails closed before deleting anything.
"""

from __future__ import annotations

import argparse
import errno
import os
import re
import stat
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


# Anything outside printable ASCII (control characters, escape sequences) is
# shown as "?", so a file name cannot rewrite the terminal.
_UNPRINTABLE = re.compile(r"[^ a-zA-Z0-9!@#$%^&*()_+={}[\]|\\:;\"'<>,.?/\\~`-]")


def _display_path(path: str, root: str) -> str:
    sanitized = _UNPRINTABLE.sub("?", path)
    sanitized_root = _UNPRINTABLE.sub("?", root)
    if sanitized.startswith(sanitized_root):
        return sanitized[len(sanitized_root) :].lstrip(os.sep) or "."
    return sanitized


def progress(
    path: str, root: str, before: str = "Scanning: ", after: str = "...", newline: bool = False,
) -> None:
    """Show before + path + after: the parts are joined, never formatted.

    On a terminal the line is cut to its width, and a transient line (newline
    False) is overwritten by the next one through a carriage return.
    Elsewhere (a log, a pipe) transient lines are skipped and the others are
    written in full, without padding or carriage returns.
    """
    out = sys.stdout
    rendered = _display_path(path, root)
    if not out.isatty():
        if newline:
            out.write(before + rendered + after + "\n")
            out.flush()
        return
    width = _term_width()
    allowed = max(0, width - len(before) - len(after))
    line = (before + rendered[:allowed] + after)[:width]
    out.write(line.ljust(width) + ("\n" if newline else "\r"))
    out.flush()


def _report_error(path: str, root: str, action: str, error: OSError) -> None:
    progress(path, root, before=action + " (", after="): " + str(error), newline=True)


def _linux_mount_points() -> set[str]:
    """Read this process's mount namespace, including same-device bind mounts."""
    if not sys.platform.startswith("linux"):
        return set()
    mount_points = set()
    with open("/proc/self/mountinfo", encoding="utf-8", errors="surrogateescape") as table:
        for line in table:
            fields = line.split()
            if len(fields) < 10 or "-" not in fields[6:]:
                raise OSError(errno.EINVAL, "Malformed Linux mount table", "/proc/self/mountinfo")
            # mountinfo escapes whitespace and backslashes as octal sequences.
            # Decode once: a literal '\\040' is encoded '\\134040', not a space.
            decoded = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), fields[4])
            mount_points.add(os.path.normpath(decoded))
    if not mount_points:
        raise OSError(errno.EINVAL, "Empty Linux mount table", "/proc/self/mountinfo")
    return mount_points


def _is_mount_boundary(path: str, mount_points: set[str]) -> bool:
    # A link to a mount is still a link, not another filesystem to traverse.
    return not os.path.islink(path) and (
        os.path.ismount(path) or os.path.realpath(path) in mount_points
    )


# Check capabilities once: unsupported platforms fail closed rather than falling
# back to path-based deletion, for the sweep and the recycle-bin purge alike.
# Python 3.9+ on macOS/Linux provides these APIs. Keeping the check separate
# also lets tests simulate unavailable descriptor support without executing an
# unsafe fallback.
_FD_PURGE_SUPPORTED = (
    hasattr(os, "O_DIRECTORY")
    and hasattr(os, "O_NOFOLLOW")
    and all(fn in os.supports_dir_fd for fn in (os.open, os.stat, os.unlink, os.rmdir))
    and os.scandir in os.supports_fd
    and os.stat in os.supports_follow_symlinks
)


def _same_entry(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino, left.st_mode) == (right.st_dev, right.st_ino, right.st_mode)


def _require_same_entry(observed: os.stat_result, current: os.stat_result, path: str) -> None:
    if not _same_entry(observed, current):
        raise OSError(errno.ESTALE, "Entry changed during recycle-bin purge", path)


def _open_purge_directory(name: str, parent_fd: int | None, observed: os.stat_result, path: str) -> int:
    descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        _require_same_entry(observed, os.fstat(descriptor), path)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def _purge_error(path: str, root: str, result: Result, error: OSError) -> None:
    result.failures += 1
    _report_error(path, root, "Could not remove", error)


def _purge_mount(path: str, root: str, result: Result) -> None:
    result.skipped_mounts += 1
    progress(path, root, before="Skipping mounted filesystem ", newline=True)


def _purge_tree(
    path: str, root: str, dry_run: bool, result: Result, mount_points: set[str] | None = None,
) -> tuple[bool, int]:
    """Anchor the purge to the selected root, opening each parent without links."""
    parent_fd = None
    try:
        if not _FD_PURGE_SUPPORTED:
            raise OSError(errno.ENOTSUP, "Safe descriptor-relative recycle purge is unavailable", path)
        if mount_points is None:
            mount_points = _linux_mount_points()
        relative = os.path.relpath(path, root)
        parts = relative.split(os.sep)
        if relative == "." or ".." in parts:
            raise OSError(errno.EINVAL, "Recycle bin must be below the scan root", path)
        observed = os.stat(root, follow_symlinks=False)
        parent_fd = _open_purge_directory(root, None, observed, root)
        display = root
        for name in parts[:-1]:
            display = os.path.join(display, name)
            observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if observed.st_dev != os.fstat(parent_fd).st_dev or _is_mount_boundary(display, mount_points):
                _purge_mount(display, root, result)
                return False, 0
            next_fd = _open_purge_directory(name, parent_fd, observed, display)
            os.close(parent_fd)
            parent_fd = next_fd
        observed = os.stat(parts[-1], dir_fd=parent_fd, follow_symlinks=False)
        return _purge_entry(parts[-1], parent_fd, observed, path, root, dry_run, result, mount_points)
    except OSError as error:
        _purge_error(path, root, result, error)
        return False, 0
    finally:
        if parent_fd is not None:
            os.close(parent_fd)


def _purge_entry(
    name: str, parent_fd: int, observed: os.stat_result, path: str,
    root: str, dry_run: bool, result: Result, mount_points: set[str],
) -> tuple[bool, int]:
    """Purge an anchored entry without following a raced directory replacement.

    A fully removed subtree counts once; a partial purge counts its fully
    removed child subtrees. Dry runs use the identical traversal and accounting.
    Full paths are for display/mount checks only, never traversal or deletion.
    """
    removed = 0
    directory_fd = None
    try:
        _require_same_entry(observed, os.stat(name, dir_fd=parent_fd, follow_symlinks=False), path)
        if observed.st_dev != os.fstat(parent_fd).st_dev or _is_mount_boundary(path, mount_points):
            _purge_mount(path, root, result)
            return False, 0
        is_directory = stat.S_ISDIR(observed.st_mode)
        if is_directory:
            directory_fd = _open_purge_directory(name, parent_fd, observed, path)
            # The opened descriptor and the parent's entry must still identify
            # the same directory before enumerating it.
            _require_same_entry(observed, os.stat(name, dir_fd=parent_fd, follow_symlinks=False), path)
            with os.scandir(directory_fd) as entries:
                children = [(entry.name, entry.stat(follow_symlinks=False)) for entry in entries]
            complete = True
            for child_name, child_stat in children:
                child_complete, child_removed = _purge_entry(
                    child_name, directory_fd, child_stat, os.path.join(path, child_name),
                    root, dry_run, result, mount_points,
                )
                complete = child_complete and complete
                removed += child_removed
            if not complete:
                return False, removed
        _require_same_entry(observed, os.stat(name, dir_fd=parent_fd, follow_symlinks=False), path)
        progress(path, root, before="Would remove " if dry_run else "Removing ", newline=True)
        if not dry_run:
            if is_directory:
                os.rmdir(name, dir_fd=parent_fd)
            else:
                os.unlink(name, dir_fd=parent_fd)
        return True, 1
    except OSError as error:
        _purge_error(path, root, result, error)
        return False, removed
    finally:
        if directory_fd is not None:
            os.close(directory_fd)


def _directory_key(path: str) -> tuple[int, int]:
    info = os.stat(path, follow_symlinks=False)
    return info.st_dev, info.st_ino


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

    try:
        if not _FD_PURGE_SUPPORTED:
            raise OSError(errno.ENOTSUP, "Safe descriptor-relative deletion is unavailable", root)
        mount_points = _linux_mount_points()
    except OSError as error:
        _purge_error(root, root, result, error)
        return result

    try:
        root_fd = _open_purge_directory(root, None, os.stat(root, follow_symlinks=False), root)
    except OSError as error:
        _walk_error(root, root, result, error)
        return result

    # Depth first without recursion (no limit on tree depth): each frame is an
    # open directory and an iterator over the subdirectories still to visit in
    # it, so only the current branch's descriptors are open. A child is opened
    # relative to its parent's descriptor with O_NOFOLLOW and must still be
    # the directory that was listed.
    # A descriptor is on the stack from the moment it is opened, so the
    # finally clause closes every one still open, whatever interrupts the walk.
    stack = [(root_fd, iter(()))]
    try:
        progress(root, root)
        stack[-1] = (root_fd, iter(_clean_directory(
            root_fd, root, root, dry_run, purge_recycle_bins, result, mount_points)))
        while stack:
            parent_fd, pending = stack[-1]
            child = next(pending, None)
            if child is None:
                stack.pop()
                os.close(parent_fd)
                continue
            name, observed, path = child
            try:
                child_fd = _open_purge_directory(name, parent_fd, observed, path)
            except OSError as error:
                _walk_error(path, root, result, error)
                continue
            stack.append((child_fd, iter(())))
            progress(path, root)
            stack[-1] = (child_fd, iter(_clean_directory(
                child_fd, path, root, dry_run, purge_recycle_bins, result, mount_points)))
    finally:
        for directory_fd, _ in reversed(stack):
            os.close(directory_fd)
    return result


def _walk_error(path: str, root: str, result: Result, error: OSError) -> None:
    if getattr(error, "errno", None) in (errno.EACCES, errno.EPERM):
        # macOS TCC/SIP blocks traversal of protected trees (Mail, Photos,
        # ...) even under sudo. That is "nothing to clean here", not a
        # deletion failure, so a clean sweep still exits 0.
        result.skipped_unreadable += 1
        _report_error(path, root, "Skipping unreadable", error)
        return
    result.failures += 1
    _report_error(path, root, "Could not scan", error)


def _remove_metadata(
    name: str, parent_fd: int, path: str, root: str, dry_run: bool, result: Result,
) -> None:
    """Unlink one metadata file by name, relative to its open directory."""
    progress(path, root, before="Would remove " if dry_run else "Removing ", newline=True)
    if dry_run:
        result.removed += 1
        return
    try:
        os.unlink(name, dir_fd=parent_fd)
        result.removed += 1
    except OSError as error:
        # A metadata file found but not deletable (permission, immutable
        # flag, I/O) is a genuine failure the caller should see, unlike a
        # directory that could not even be entered (_walk_error).
        result.failures += 1
        _report_error(path, root, "Could not remove", error)


def _clean_directory(
    directory_fd: int, path: str, root: str, dry_run: bool, purge_recycle_bins: bool,
    result: Result, mount_points: set[str],
) -> list[tuple[str, os.stat_result, str]]:
    """Clean one open directory; return the subdirectories to descend into.

    Entries are classified as os.walk classifies them (a symlink to a
    directory counts as a directory but is never entered), so the same names
    are removed, kept or purged as before.
    """
    try:
        with os.scandir(directory_fd) as entries:
            listed = list(entries)
        device = os.fstat(directory_fd).st_dev
    except OSError as error:
        _walk_error(path, root, result, error)
        return []
    subdirectories = []
    for entry in listed:
        name = entry.name
        candidate = os.path.join(path, name)
        try:
            is_directory = entry.is_dir()
        except OSError:
            is_directory = False
        if not is_directory:
            if name in METADATA_FILES:
                if _is_mount_boundary(candidate, mount_points):
                    _purge_mount(candidate, root, result)
                    continue
                _remove_metadata(name, directory_fd, candidate, root, dry_run, result)
            continue
        if _is_mount_boundary(candidate, mount_points):
            _purge_mount(candidate, root, result)
            continue
        if name == RECYCLE_BIN:
            if purge_recycle_bins:
                _, removed = _purge_tree(candidate, root, dry_run, result, mount_points)
                result.removed += removed
            continue
        if entry.is_symlink():
            continue
        try:
            observed = entry.stat(follow_symlinks=False)
        except OSError as error:
            _walk_error(candidate, root, result, error)
            continue
        if observed.st_dev != device:
            _purge_mount(candidate, root, result)
            continue
        subdirectories.append((name, observed, candidate))
    return subdirectories


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
