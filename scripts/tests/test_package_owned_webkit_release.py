import importlib.util
import hashlib
import json
from unittest.mock import patch
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "package-owned-webkit-release.py"
SPEC = importlib.util.spec_from_file_location("package_owned_webkit_release", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OwnedWebKitReleaseContractTests(unittest.TestCase):
    def setUp(self):
        self.info = {
            "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "139",
        }

    def test_accepts_only_versioned_production_manager_and_existing_signer(self):
        MODULE.validate_manager_info(self.info, MODULE.IDENTITY_SHA1)

    def test_rejects_development_bundle(self):
        info = {**self.info, "CFBundleIdentifier": "app.neantik.desktop.dev"}
        with self.assertRaisesRegex(MODULE.PackageError, "production manager"):
            MODULE.validate_manager_info(info, MODULE.IDENTITY_SHA1)

    def test_rejects_non_1_0_release(self):
        info = {**self.info, "CFBundleShortVersionString": "0.8.26"}
        with self.assertRaisesRegex(MODULE.PackageError, "1.0.0"):
            MODULE.validate_manager_info(info, MODULE.IDENTITY_SHA1)

    def test_rejects_old_or_malformed_build_number(self):
        for build in ("138", "one-hundred-thirty-nine"):
            with self.subTest(build=build), self.assertRaises(MODULE.PackageError):
                MODULE.validate_manager_info({**self.info, "CFBundleVersion": build},
                                             MODULE.IDENTITY_SHA1)

    def test_rejects_qa_metadata(self):
        info = {**self.info, "NeAntikBackupQualificationRunID": "qa-only"}
        with self.assertRaisesRegex(MODULE.PackageError, "QA manager metadata"):
            MODULE.validate_manager_info(info, MODULE.IDENTITY_SHA1)

    def test_rejects_different_signing_identity(self):
        with self.assertRaisesRegex(MODULE.PackageError, "existing pinned Developer ID"):
            MODULE.validate_manager_info(self.info, "0" * 40)

    def test_selects_rebound_production_host_and_binds_its_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            system = Path(temporary) / "host-system"
            owned = Path(temporary) / "host-owned"
            system.write_bytes(b"system linked")
            owned.write_bytes(b"bundle linked")
            receipt = {
                "status": "built-production-mode-unqualified",
                "qaProxy": False,
                "productionProxy": True,
                "binary": str(system),
                "binarySHA256": MODULE.sha256(system),
                "ownedBinary": str(owned),
                "ownedSHA256": MODULE.sha256(owned),
            }
            self.assertEqual(MODULE.production_host_binary(receipt), owned)
            receipt["ownedSHA256"] = "0" * 64
            with self.assertRaisesRegex(MODULE.PackageError, "changed"):
                MODULE.production_host_binary(receipt)

    def test_source_archive_identity_does_not_require_local_git_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "WebKit.tar.zst"
            receipt = Path(temporary) / "recovery.json"
            payload = b"verified source archive fixture"
            archive.write_bytes(payload)
            receipt.write_text(json.dumps({
                "status": "exact-source-commit-recovered-and-patched;offer-incomplete",
                "repository": "https://github.com/WebKit/WebKit",
                "commit": MODULE.EXPECTED_COMMIT,
                "tree": MODULE.SOURCE_TREE,
                "sourceArchiveBytes": len(payload),
                "sourceArchiveSHA256": hashlib.sha256(payload).hexdigest(),
                "patchSHA256": MODULE.EXPECTED_PATCH_SHA256,
            }))
            with patch.object(MODULE, "SOURCE_ARCHIVE", archive), \
                    patch.object(MODULE, "SOURCE_RECOVERY", receipt), \
                    patch.object(MODULE, "SOURCE_ARCHIVE_SHA256", hashlib.sha256(payload).hexdigest()):
                MODULE.verify_source_archive_identity()

    def test_rejects_source_archive_receipt_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "WebKit.tar.zst"
            receipt = Path(temporary) / "recovery.json"
            archive.write_bytes(b"changed source")
            receipt.write_text(json.dumps({
                "status": "exact-source-commit-recovered-and-patched;offer-incomplete",
                "repository": "https://github.com/WebKit/WebKit",
                "commit": MODULE.EXPECTED_COMMIT,
                "tree": MODULE.SOURCE_TREE,
                "sourceArchiveBytes": len(b"original source"),
                "sourceArchiveSHA256": MODULE.SOURCE_ARCHIVE_SHA256,
                "patchSHA256": MODULE.EXPECTED_PATCH_SHA256,
            }))
            with patch.object(MODULE, "SOURCE_ARCHIVE", archive), \
                    patch.object(MODULE, "SOURCE_RECOVERY", receipt):
                with self.assertRaisesRegex(MODULE.PackageError, "does not match"):
                    MODULE.verify_source_archive_identity()


if __name__ == "__main__":
    unittest.main()
