#!/usr/bin/env python3
"""Behavioural tests for the metadata cleaner."""

from __future__ import annotations

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

    def test_invalid_root_is_an_error(self) -> None:
        self.assertEqual(rmdsstore.main(["/definitely-not-a-real-leos-root"]), 2)

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

    def test_walk_errors_are_reported_as_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def inaccessible_walk(*_args: object, **kwargs: object) -> list[object]:
                onerror = kwargs["onerror"]
                assert callable(onerror)
                onerror(PermissionError(13, "Permission denied", directory))
                return []

            with mock.patch.object(rmdsstore.os, "walk", side_effect=inaccessible_walk):
                result = rmdsstore.scan(directory, dry_run=True)
            self.assertEqual(result.failures, 1)

    def test_walk_errors_with_braces_do_not_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def brace_walk(*_args: object, **kwargs: object) -> list[object]:
                onerror = kwargs["onerror"]
                assert callable(onerror)
                onerror(PermissionError(13, "denied {oops}", directory + "/{weird}"))
                return []

            with mock.patch.object(rmdsstore.os, "walk", side_effect=brace_walk):
                result = rmdsstore.scan(directory, dry_run=True)
            self.assertEqual(result.failures, 1)


if __name__ == "__main__":
    unittest.main()
