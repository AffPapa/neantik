import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runtime_locked_overlay import apply_overlay, digest


class LockedOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.payload = self.root / "payload"
        self.source.mkdir()
        self.payload.mkdir()
        (self.source / "a").write_bytes(b"before")
        (self.payload / "a").write_bytes(b"after")
        (self.payload / "b").write_bytes(b"new")
        self.records = [dict(path="a", preimageSHA256=digest(b"before"), postimageSHA256=digest(b"after")),
                        dict(path="b", preimageSHA256=None, postimageSHA256=digest(b"new"))]

    def test_commit_and_repeated_apply_rejected(self):
        apply_overlay(self.source, self.payload, self.records)
        self.assertEqual((self.source / "a").read_bytes(), b"after")
        self.assertEqual((self.source / "b").read_bytes(), b"new")
        with self.assertRaises(ValueError):
            apply_overlay(self.source, self.payload, self.records)

    def test_late_bad_postimage_does_not_write_first(self):
        (self.payload / "b").write_bytes(b"wrong")
        with self.assertRaises(ValueError):
            apply_overlay(self.source, self.payload, self.records)
        self.assertEqual((self.source / "a").read_bytes(), b"before")

    def test_disk_failure_rolls_back_existing_and_new_files(self):
        import os
        calls = []
        def failing_replace(src, dst):
            calls.append(dst)
            if len(calls) == 2:
                raise OSError("synthetic disk full")
            os.replace(src, dst)
        with self.assertRaises(OSError):
            apply_overlay(self.source, self.payload, self.records, failing_replace)
        self.assertEqual((self.source / "a").read_bytes(), b"before")
        self.assertFalse((self.source / "b").exists())
        self.assertFalse(list(self.source.glob("*.neantik-*")))

    def test_fsync_failure_cleans_own_temporary_and_can_retry(self):
        with patch("runtime_locked_overlay.os.fsync", side_effect=OSError("synthetic disk full")):
            with self.assertRaises(OSError):
                apply_overlay(self.source, self.payload, self.records)
        self.assertEqual((self.source / "a").read_bytes(), b"before")
        self.assertFalse(list(self.source.glob("*.neantik-*")))
        apply_overlay(self.source, self.payload, self.records)
        self.assertEqual((self.source / "a").read_bytes(), b"after")

    def test_existing_temporary_is_preserved(self):
        temporary = self.source / "a.neantik-overlay-tmp"
        temporary.write_bytes(b"other operation")
        with self.assertRaises(FileExistsError):
            apply_overlay(self.source, self.payload, self.records)
        self.assertEqual(temporary.read_bytes(), b"other operation")
        self.assertEqual((self.source / "a").read_bytes(), b"before")

    def test_symlink_and_traversal_rejected(self):
        (self.source / "b").symlink_to(self.root / "outside")
        with self.assertRaises(ValueError):
            apply_overlay(self.source, self.payload, self.records)

    def test_receipt_disk_failure_rolls_back_entire_batch(self):
        def failed_receipt():
            raise OSError("synthetic receipt permission denied")
        with self.assertRaises(OSError):
            apply_overlay(self.source, self.payload, self.records, commit_receipt=failed_receipt)
        self.assertEqual((self.source / "a").read_bytes(), b"before")
        self.assertFalse((self.source / "b").exists())

    def test_unrelated_edit_preserved_while_other_targets_roll_back(self):
        import os
        def concurrent_writer(src, dst):
            os.replace(src, dst)
            if dst.name == "b":
                dst.write_bytes(b"unrelated")
        with self.assertRaisesRegex(ValueError, "rollback incomplete: b"):
            apply_overlay(self.source, self.payload, self.records, concurrent_writer)
        self.assertEqual((self.source / "a").read_bytes(), b"before")
        self.assertEqual((self.source / "b").read_bytes(), b"unrelated")
        self.records[0]["path"] = "../outside"
        with self.assertRaises(ValueError):
            apply_overlay(self.source, self.payload, self.records)


if __name__ == "__main__":
    unittest.main()
