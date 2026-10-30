"""Fault controls for immutable source-evidence publication, not qualification."""
import importlib.util
import os
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import sys

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("freeze_m155", SCRIPTS / "freeze-chromium-15540-candidate.py")
freeze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(freeze)


class FrozenEvidenceTransactionTests(unittest.TestCase):
    def test_prebuild_inventory_cannot_be_rebaselined_after_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "prebuild.json"
            snapshot = {"entriesSHA256": "a" * 64, "argsGN": {"sha256": "b" * 64}}
            target.write_text(json.dumps(snapshot))
            plan = {"buildPolicy": {"sourceInputSnapshotSHA256": freeze.digest(target)}}
            self.assertEqual(freeze.verify_prebuild_snapshot(target, snapshot, plan), freeze.digest(target))
            for field in ("entriesSHA256", "argsGN"):
                changed = dict(snapshot, **{field: "changed"})
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, "changed after"):
                    freeze.verify_prebuild_snapshot(target, changed, plan)
            target.write_text(json.dumps({"entriesSHA256": "changed"}))
            with self.assertRaisesRegex(ValueError, "differs from reviewed"):
                freeze.verify_prebuild_snapshot(target, snapshot, plan)

    def test_prebuild_snapshot_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "prebuild.json"
            target.write_text("{}")
            link = Path(directory) / "linked.json"
            link.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "regular pre-build"):
                freeze.verify_prebuild_snapshot(link, {}, {"buildPolicy": {"sourceInputSnapshotSHA256": freeze.digest(target)}})

    def test_publish_is_durable_and_rollback_removes_own_record(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "contract.json"
            created = []
            with patch.object(freeze.os, "fsync", wraps=os.fsync) as sync:
                freeze.write_new(target, {"releaseReady": False}, created)
            self.assertEqual(sync.call_count, 2)
            self.assertTrue(target.is_file())
            self.assertFalse(target.with_name(target.name + ".tmp").exists())
            freeze.remove_owned(created[0])
            self.assertFalse(target.exists())

    def test_competing_destination_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "contract.json"
            original_link = os.link
            def competing_link(source, destination, **kwargs):
                target.write_bytes(b"foreign evidence")
                return original_link(source, destination, **kwargs)
            created = []
            with patch.object(freeze.os, "link", side_effect=competing_link), self.assertRaises(FileExistsError):
                freeze.write_new(target, {"releaseReady": False}, created)
            self.assertEqual(target.read_bytes(), b"foreign evidence")
            self.assertEqual(created, [])
            self.assertFalse(target.with_name(target.name + ".tmp").exists())

    def test_file_fsync_failure_leaves_no_public_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "contract.json"
            created = []
            with patch.object(freeze.os, "fsync", side_effect=OSError("injected disk failure")), self.assertRaises(OSError):
                freeze.write_new(target, {}, created)
            self.assertEqual(list(Path(directory).iterdir()), [])
            self.assertEqual(created, [])

    def test_directory_fsync_failure_is_included_in_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "contract.json"
            created = []
            with patch.object(freeze.os, "fsync", side_effect=[None, OSError("injected directory failure")]), self.assertRaises(OSError):
                freeze.write_new(target, {}, created)
            self.assertEqual(len(created), 1)
            freeze.remove_owned(created[0])
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_rollback_preserves_foreign_edit_and_replacement(self):
        for replacement in (False, True):
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / "contract.json"
                created = []
                freeze.write_new(target, {}, created)
                if replacement:
                    target.unlink()
                target.write_bytes(b"foreign edit")
                freeze.remove_owned(created[0])
                self.assertEqual(target.read_bytes(), b"foreign edit")

    def test_preexisting_temporary_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "contract.json"
            temporary = target.with_name(target.name + ".tmp")
            temporary.write_bytes(b"foreign temporary")
            with self.assertRaises(ValueError):
                freeze.write_new(target, {}, [])
            self.assertEqual(temporary.read_bytes(), b"foreign temporary")


if __name__ == "__main__":
    unittest.main()
