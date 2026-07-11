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


if __name__ == "__main__":
    unittest.main()
