"""Exact-ZIP delta controls for the owned WebKit release review queue."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
import warnings
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "compare-webkit-framework-inventory.py"
SPEC = importlib.util.spec_from_file_location("webkit_framework_delta", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class FrameworkInventoryDeltaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "candidate.zip"
        self.baseline = self.root / "baseline.json"
        self.rows = [
            {"path": "WebKit.framework/Versions/A/WebKit", "kind": "Mach-O", "bytes": 8,
             "sha256": hashlib.sha256(bytes.fromhex("cffaedfe") + b"old!").hexdigest()},
            {"path": "WebKit.framework/Versions/Current", "kind": "symlink", "target": "A"},
        ]
        self.baseline.write_text(json.dumps({"schemaVersion": 1, "candidateSHA256": "0" * 64,
            "scopes": {"ownedWebKitFrameworks": {"entryCount": len(self.rows), "entries": self.rows}}}))

    def _zip(self, *, changed: bool = False, duplicate: bool = False) -> str:
        with zipfile.ZipFile(self.archive, "w") as archive:
            image = zipfile.ZipInfo(MODULE.FRAMEWORK_PREFIX + "WebKit.framework/Versions/A/WebKit")
            image.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(image, bytes.fromhex("cffaedfe") + (b"new!" if changed else b"old!"))
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(image, bytes.fromhex("cffaedfe") + b"old!")
            link = zipfile.ZipInfo(MODULE.FRAMEWORK_PREFIX + "WebKit.framework/Versions/Current")
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, b"A")
            archive.writestr("__MACOSX/NeAntik.app/._WebKit", b"metadata")
        return hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def test_unchanged_files_and_macos_sidecar_are_reused(self) -> None:
        digest = self._zip()
        report = MODULE.compare(self.archive, self.baseline, digest)
        self.assertEqual(report["counts"], {"baseline": 2, "candidate": 2,
                         "unchanged": 2, "changed": 0, "added": 0, "missing": 0})
        self.assertEqual(report["reviewQueue"], [])

    def test_changed_image_is_queued_without_license_decision(self) -> None:
        digest = self._zip(changed=True)
        report = MODULE.compare(self.archive, self.baseline, digest)
        self.assertEqual(report["counts"]["changed"], 1)
        self.assertEqual(report["reviewQueue"][0]["status"], "changed")
        self.assertIn("unproved", report["qualification"])

    def test_wrong_archive_hash_fails_before_inventory(self) -> None:
        self._zip()
        with self.assertRaisesRegex(MODULE.InventoryError, "SHA-256 mismatch"):
            MODULE.compare(self.archive, self.baseline, "f" * 64)

    def test_duplicate_member_fails_closed(self) -> None:
        digest = self._zip(duplicate=True)
        with self.assertRaisesRegex(MODULE.InventoryError, "duplicate"):
            MODULE.compare(self.archive, self.baseline, digest)


if __name__ == "__main__":
    unittest.main()
