#!/usr/bin/env python3
"""Behavioural tests for the metadata cleaner."""

from __future__ import annotations

import errno
import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("rmdsstore", ROOT / "util" / "rmdsstore.py")
assert SPEC and SPEC.loader
rmdsstore = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = rmdsstore
SPEC.loader.exec_module(rmdsstore)


class RmdsstoreTest(unittest.TestCase):
    def test_dry_run_does_not_delete_and_real_run_does(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nested = root / "nested"
            nested.mkdir()
            for path in (root / ".DS_Store", nested / "Thumbs.db", nested / "desktop.ini"):
                path.write_text("metadata", encoding="utf-8")
            recycle = root / "$RECYCLE.BIN"
            recycle.mkdir()
            (recycle / "item").write_text("metadata", encoding="utf-8")

            dry_result = rmdsstore.scan(str(root), dry_run=True)
            self.assertEqual(dry_result.removed, 3)
            self.assertTrue((root / ".DS_Store").exists())
            self.assertTrue(recycle.exists())

            result = rmdsstore.scan(str(root), dry_run=False)
            self.assertEqual(result.removed, 3)
            self.assertFalse((root / ".DS_Store").exists())
            self.assertFalse((nested / "Thumbs.db").exists())
            self.assertFalse((nested / "desktop.ini").exists())
            self.assertTrue(recycle.exists())

            purge = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)
            self.assertEqual(purge.removed, 1)
            self.assertFalse(recycle.exists())

    def test_symlink_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory) / "target"
            target.mkdir()
            link = pathlib.Path(directory) / "link"
            link.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                rmdsstore.scan(str(link), dry_run=True)
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                rmdsstore.scan(f"{link}/", dry_run=True)

    def test_recycle_purge_preserves_nested_mount_and_ancestors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            ancestor = recycle / "nested"
            mounted = ancestor / "mounted"
            mounted.mkdir(parents=True)
            protected = mounted / "important.txt"
            protected.write_text("keep", encoding="utf-8")
            ordinary = ancestor / "ordinary.txt"
            ordinary.write_text("remove", encoding="utf-8")
            sibling = recycle / "ordinary-tree"
            sibling.mkdir()
            (sibling / "item").write_text("remove", encoding="utf-8")

            real_scandir = rmdsstore.os.scandir

            def guarded_scandir(path):
                if isinstance(path, int):
                    self.assertNotEqual(rmdsstore.os.fstat(path).st_ino, mounted.stat().st_ino,
                                        "entered nested mount")
                else:
                    self.assertNotEqual(pathlib.Path(path), mounted, "entered nested mount")
                return real_scandir(path)

            with mock.patch.object(
                rmdsstore.os.path, "ismount", side_effect=lambda path: pathlib.Path(path) == mounted
            ), mock.patch.object(rmdsstore.os, "scandir", side_effect=guarded_scandir):
                dry = rmdsstore.scan(str(root), dry_run=True, purge_recycle_bins=True)
                self.assertTrue(ordinary.exists())
                self.assertTrue(sibling.exists())
                actual = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertEqual(dry, actual)
            self.assertEqual(actual.removed, 2)
            self.assertEqual(actual.skipped_mounts, 1)
            self.assertEqual(actual.failures, 0)
            self.assertEqual(protected.read_text(encoding="utf-8"), "keep")
            self.assertTrue(ancestor.exists())
            self.assertTrue(recycle.exists())
            self.assertFalse(ordinary.exists())
            self.assertFalse(sibling.exists())

    def test_recycle_purge_unlinks_symlinks_without_entering_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "target"
            target.mkdir()
            protected = target / "important.txt"
            protected.write_text("keep", encoding="utf-8")
            recycle = root / "$RECYCLE.BIN"
            recycle.mkdir()
            (recycle / "link").symlink_to(target, target_is_directory=True)
            (recycle / "dangling").symlink_to(root / "absent")
            (recycle / "cycle").symlink_to(recycle, target_is_directory=True)

            dry = rmdsstore.scan(str(root), dry_run=True, purge_recycle_bins=True)
            self.assertTrue((recycle / "link").is_symlink())
            actual = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertEqual(dry, actual)
            self.assertEqual(actual.removed, 1)
            self.assertFalse(recycle.exists())
            self.assertEqual(protected.read_text(encoding="utf-8"), "keep")

    def test_recycle_purge_deletion_error_is_failure_and_keeps_ancestors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            recycle.mkdir()
            blocked = recycle / "{blocked}"
            blocked.write_text("keep", encoding="utf-8")
            ordinary = recycle / "ordinary"
            ordinary.write_text("remove", encoding="utf-8")
            real_unlink = rmdsstore.os.unlink

            def unlink(path: str, *, dir_fd=None) -> None:
                if path == blocked.name:
                    raise PermissionError(errno.EACCES, "denied {oops}", path)
                real_unlink(path, dir_fd=dir_fd)

            with mock.patch.object(rmdsstore.os, "unlink", side_effect=unlink):
                result = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertEqual(result.failures, 1)
            self.assertEqual(result.skipped_unreadable, 0)
            self.assertEqual(result.removed, 1)
            self.assertTrue(blocked.exists())
            self.assertFalse(ordinary.exists())

    def test_recycle_purge_scan_error_has_dry_run_parity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            recycle.mkdir()
            real_scandir = rmdsstore.os.scandir

            def scandir(path):
                if isinstance(path, int) and rmdsstore.os.fstat(path).st_ino == recycle.stat().st_ino:
                    raise OSError(errno.EIO, "I/O error", str(recycle))
                return real_scandir(path)

            with mock.patch.object(rmdsstore.os, "scandir", side_effect=scandir):
                dry = rmdsstore.scan(str(root), dry_run=True, purge_recycle_bins=True)
                actual = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertEqual(dry, actual)
            self.assertEqual(actual.failures, 1)
            self.assertEqual(actual.removed, 0)
            self.assertTrue(recycle.exists())

    def test_recycle_bin_symlink_is_unlinked_without_purging_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "target"
            target.mkdir()
            protected = target / "important.txt"
            protected.write_text("keep", encoding="utf-8")
            recycle = root / "$RECYCLE.BIN"
            recycle.symlink_to(target, target_is_directory=True)

            result = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertEqual(result.removed, 1)
            self.assertEqual(result.failures, 0)
            self.assertFalse(recycle.is_symlink())
            self.assertEqual(protected.read_text(encoding="utf-8"), "keep")

    def test_recycle_purge_rmdir_failure_reports_partial_removals(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            recycle.mkdir()
            ordinary = recycle / "ordinary"
            ordinary.write_text("remove", encoding="utf-8")

            with mock.patch.object(
                rmdsstore.os, "rmdir", side_effect=PermissionError(errno.EACCES, "denied")
            ):
                result = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertEqual(result.failures, 1)
            self.assertEqual(result.removed, 1)
            self.assertTrue(recycle.exists())
            self.assertFalse(ordinary.exists())

    def test_invalid_root_is_an_error(self) -> None:
        self.assertEqual(rmdsstore.main(["/definitely-not-a-real-leos-root"]), 2)

    def test_recycle_purge_directory_swap_never_enters_symlink_target(self) -> None:
        for dry_run in (True, False):
            with self.subTest(dry_run=dry_run), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                recycle = root / "$RECYCLE.BIN"
                victim = recycle / "nested"
                victim.mkdir(parents=True)
                outside = root / "outside"
                outside.mkdir()
                protected = outside / "important.txt"
                protected.write_text("keep", encoding="utf-8")
                real_open = rmdsstore.os.open
                swapped = False

                def swapping_open(path, flags, mode=0o777, *, dir_fd=None):
                    nonlocal swapped
                    if path == "nested" and dir_fd is not None and not swapped:
                        swapped = True
                        victim.rename(recycle / "moved")
                        victim.symlink_to(outside, target_is_directory=True)
                    return real_open(path, flags, mode, dir_fd=dir_fd)

                with mock.patch.object(rmdsstore.os, "open", side_effect=swapping_open):
                    result = rmdsstore.scan(str(root), dry_run=dry_run, purge_recycle_bins=True)

                self.assertTrue(swapped)
                self.assertEqual(result.failures, 1)
                self.assertEqual(result.removed, 0)
                self.assertEqual(protected.read_text(encoding="utf-8"), "keep")
                self.assertTrue(recycle.exists())

    def test_recycle_purge_without_descriptor_support_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            recycle.mkdir()
            protected = recycle / "item"
            protected.write_text("keep", encoding="utf-8")
            with mock.patch.object(rmdsstore, "_FD_PURGE_SUPPORTED", False):
                result = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)
            self.assertEqual(result.failures, 1)
            self.assertEqual(result.removed, 0)
            self.assertEqual(protected.read_text(encoding="utf-8"), "keep")

    def test_recycle_purge_rejects_different_directory_inode_after_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            victim = recycle / "nested"
            victim.mkdir(parents=True)
            real_open = rmdsstore.os.open
            swapped = False

            def swapping_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal swapped
                if path == "nested" and dir_fd is not None and not swapped:
                    swapped = True
                    victim.rename(recycle / "moved")
                    victim.mkdir()
                    (victim / "replacement").write_text("keep", encoding="utf-8")
                return real_open(path, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(rmdsstore.os, "open", side_effect=swapping_open):
                result = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertTrue(swapped)
            self.assertEqual(result.failures, 1)
            self.assertEqual(result.removed, 0)
            self.assertEqual((victim / "replacement").read_text(encoding="utf-8"), "keep")

    def test_linux_same_device_bind_mount_with_escaped_path_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            mounted = recycle / "nested" / "bound space\ttab\nline\\040"
            mounted.mkdir(parents=True)
            protected = mounted / "important.txt"
            protected.write_text("keep", encoding="utf-8")
            ordinary = recycle / "ordinary"
            ordinary.write_text("remove", encoding="utf-8")
            self.assertEqual(mounted.stat().st_dev, recycle.stat().st_dev)
            escaped = str(mounted.resolve()).replace("\\", r"\134").replace(" ", r"\040")
            escaped = escaped.replace("\t", r"\011").replace("\n", r"\012")
            table = f"41 20 8:1 /source {escaped} rw,relatime shared:1 - ext4 /dev/sda rw\n"

            with mock.patch.object(rmdsstore.sys, "platform", "linux"), mock.patch.object(
                rmdsstore, "open", mock.mock_open(read_data=table), create=True
            ), mock.patch.object(rmdsstore.os.path, "ismount", return_value=False):
                dry = rmdsstore.scan(str(root), dry_run=True, purge_recycle_bins=True)
                self.assertTrue(ordinary.exists())
                actual = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)

            self.assertEqual(dry, actual)
            self.assertEqual(actual.skipped_mounts, 1)
            self.assertEqual(actual.removed, 1)
            self.assertEqual(actual.failures, 0)
            self.assertEqual(protected.read_text(encoding="utf-8"), "keep")
            self.assertTrue(mounted.parent.exists())
            self.assertTrue(recycle.exists())
            self.assertFalse(ordinary.exists())

    def test_linux_bind_mount_pruned_in_normal_scan_and_explicit_root_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            mounted = root / "bound"
            mounted.mkdir()
            metadata = mounted / ".DS_Store"
            metadata.write_text("metadata", encoding="utf-8")
            table = f"41 20 8:1 /source {mounted.resolve()} rw - ext4 /dev/sda rw\n"
            with mock.patch.object(rmdsstore.sys, "platform", "linux"), mock.patch.object(
                rmdsstore, "open", mock.mock_open(read_data=table), create=True
            ), mock.patch.object(rmdsstore.os.path, "ismount", return_value=False):
                skipped = rmdsstore.scan(str(root), dry_run=False)
                self.assertTrue(metadata.exists())
                explicit = rmdsstore.scan(str(mounted), dry_run=False)
            self.assertEqual(skipped.skipped_mounts, 1)
            self.assertEqual(skipped.removed, 0)
            self.assertEqual(explicit.removed, 1)
            self.assertFalse(metadata.exists())

    def test_linux_unreadable_mountinfo_fails_before_any_deletions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            recycle = root / "$RECYCLE.BIN"
            recycle.mkdir()
            protected = recycle / "important.txt"
            protected.write_text("keep", encoding="utf-8")
            metadata = root / ".DS_Store"
            metadata.write_text("metadata", encoding="utf-8")
            with mock.patch.object(rmdsstore.sys, "platform", "linux"), mock.patch.object(
                rmdsstore, "open", side_effect=PermissionError(errno.EACCES, "denied"), create=True
            ):
                dry = rmdsstore.scan(str(root), dry_run=True, purge_recycle_bins=True)
                actual = rmdsstore.scan(str(root), dry_run=False, purge_recycle_bins=True)
            self.assertEqual(dry, actual)
            self.assertEqual(actual.failures, 1)
            self.assertEqual(actual.removed, 0)
            self.assertTrue(metadata.exists())
            self.assertEqual(protected.read_text(encoding="utf-8"), "keep")

    def test_cloud_storage_and_duck_directories_are_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            cloud = root / "Library" / "CloudStorage"
            duck = root / "remote.duck"
            cloud.mkdir(parents=True)
            duck.mkdir()
            (cloud / ".DS_Store").write_text("metadata", encoding="utf-8")
            (duck / ".DS_Store").write_text("metadata", encoding="utf-8")

            result = rmdsstore.scan(str(root), dry_run=False)

            self.assertEqual(result.removed, 2)
            self.assertFalse((cloud / ".DS_Store").exists())
            self.assertFalse((duck / ".DS_Store").exists())

    def test_nested_mount_is_pruned_but_explicit_mount_root_is_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            mounted = root / "mounted"
            mounted.mkdir()
            metadata = mounted / ".DS_Store"
            metadata.write_text("metadata", encoding="utf-8")

            real_ismount = rmdsstore.os.path.ismount
            with mock.patch.object(
                rmdsstore.os.path,
                "ismount",
                side_effect=lambda path: pathlib.Path(path) == mounted or real_ismount(path),
            ):
                parent_result = rmdsstore.scan(str(root), dry_run=False)
                mount_result = rmdsstore.scan(str(mounted), dry_run=False)

            self.assertEqual(parent_result.skipped_mounts, 1)
            self.assertEqual(mount_result.removed, 1)
            self.assertFalse(metadata.exists())

    def test_default_roots_include_data_and_each_mounted_volume(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            data = base / "Data"
            volumes = base / "Volumes"
            external = volumes / "External"
            ordinary = volumes / "Ordinary"
            data.mkdir()
            external.mkdir(parents=True)
            ordinary.mkdir()
            (volumes / "Link").symlink_to(external, target_is_directory=True)

            with mock.patch.object(
                rmdsstore.os.path,
                "ismount",
                side_effect=lambda path: pathlib.Path(path) == external,
            ):
                roots = rmdsstore.discover_default_roots(str(data), str(volumes))

            self.assertEqual(roots, [str(data), str(external)])

    def test_multiple_roots_are_deduplicated_and_aggregated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / ".DS_Store").write_text("metadata", encoding="utf-8")

            status = rmdsstore.main(["--dry-run", str(root), f"{root}/"])

            self.assertEqual(status, 0)
            self.assertTrue((root / ".DS_Store").exists())

    def test_default_discovery_errors_are_reported(self) -> None:
        with mock.patch.object(
            rmdsstore, "discover_default_roots", side_effect=PermissionError("denied")
        ):
            status = rmdsstore.main([])

        self.assertEqual(status, 2)

    def test_genuine_walk_errors_are_reported_as_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def failing_walk(*_args: object, **kwargs: object) -> list[object]:
                onerror = kwargs["onerror"]
                assert callable(onerror)
                onerror(OSError(errno.EIO, "I/O error", directory))
                return []

            with mock.patch.object(rmdsstore.os, "walk", side_effect=failing_walk):
                result = rmdsstore.scan(directory, dry_run=True)
            self.assertEqual(result.failures, 1)
            self.assertEqual(result.skipped_unreadable, 0)

    def test_permission_denied_walk_is_skipped_not_failed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def denied_walk(*_args: object, **kwargs: object) -> list[object]:
                onerror = kwargs["onerror"]
                assert callable(onerror)
                onerror(PermissionError(errno.EACCES, "Permission denied", directory + "/Protected"))
                return []

            with mock.patch.object(rmdsstore.os, "walk", side_effect=denied_walk):
                result = rmdsstore.scan(directory, dry_run=True)
            self.assertEqual(result.failures, 0)
            self.assertEqual(result.skipped_unreadable, 1)

    def test_permission_denied_run_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def denied_walk(*_args: object, **kwargs: object) -> list[object]:
                onerror = kwargs["onerror"]
                assert callable(onerror)
                onerror(PermissionError(errno.EPERM, "Operation not permitted", directory))
                return []

            with mock.patch.object(rmdsstore.os, "walk", side_effect=denied_walk):
                status = rmdsstore.main([directory])
            self.assertEqual(status, 0)

    def test_remove_permission_error_is_failure_and_brace_safe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            braced = root / "{weird}"
            braced.mkdir()
            (braced / ".DS_Store").write_text("x", encoding="utf-8")

            def denied_remove(path: str, *a: object, **k: object) -> None:
                raise PermissionError(errno.EACCES, "denied {oops}", path)

            with mock.patch.object(rmdsstore.os, "remove", side_effect=denied_remove):
                result = rmdsstore.scan(str(root), dry_run=False)
            # A found-but-undeletable metadata file is a real failure, not a
            # skip, and braces in the path/error must not crash progress().
            self.assertEqual(result.failures, 1)
            self.assertEqual(result.skipped_unreadable, 0)

    def test_walk_errors_with_braces_do_not_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def brace_walk(*_args: object, **kwargs: object) -> list[object]:
                onerror = kwargs["onerror"]
                assert callable(onerror)
                onerror(PermissionError(errno.EACCES, "denied {oops}", directory + "/{weird}"))
                return []

            with mock.patch.object(rmdsstore.os, "walk", side_effect=brace_walk):
                result = rmdsstore.scan(directory, dry_run=True)
            # Permission-denied is skipped, not failed; braces in the error text
            # and path must not crash progress()'s str.format template.
            self.assertEqual(result.skipped_unreadable, 1)
            self.assertEqual(result.failures, 0)


if __name__ == "__main__":
    unittest.main()
