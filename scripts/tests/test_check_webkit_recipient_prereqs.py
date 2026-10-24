"""Bounded check-only tests for recipient WebKit prerequisite reporting."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "check-webkit-recipient-prereqs.py"
SPEC = importlib.util.spec_from_file_location("check_webkit_recipient_prereqs", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RecipientPreflightTests(unittest.TestCase):
    def test_new_hash_manifest_checks_new_archive_without_claiming_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "new-source.tar.zst"
            source.write_bytes(b"new source-only archive")
            hashes = dict(MODULE.EXPECTED, neantikArchive=hashlib.sha256(source.read_bytes()).hexdigest())
            manifest = root / "pins.json"
            manifest.write_text(json.dumps({"schemaVersion": 1,
                                            "pinnedWebKitCommit": MODULE.WEBKIT_COMMIT,
                                            "expectedSHA256": hashes}))
            args = argparse.Namespace(input_manifest=manifest, recipient_team=None,
                                      webkit_archive=None, neantik_archive=source,
                                      patch=None, build_config=None, source_tree=None,
                                      built_frameworks=None, manager_app=None, identity_sha1=None)
            with patch.object(MODULE, "check_toolchain", return_value={"status": "pass"}):
                report = MODULE.inspect(args)
            self.assertEqual(report["checks"]["neantikArchive"]["status"], "pass")
            self.assertEqual(report["inputManifestSHA256"], hashlib.sha256(manifest.read_bytes()).hexdigest())
            self.assertFalse(report["completeBuildInputsEstablished"])
            self.assertFalse(report["licenseOrSourceOfferQualified"])

    def test_hash_manifest_rejects_claims_and_bad_digests(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "pins.json"
            base = {"schemaVersion": 1, "pinnedWebKitCommit": MODULE.WEBKIT_COMMIT,
                    "expectedSHA256": dict(MODULE.EXPECTED)}
            for change in ({"completeBuildInputsEstablished": True},
                           {"schemaVersion": True},
                           {"expectedSHA256": dict(MODULE.EXPECTED, neantikArchive="0" * 63)}):
                manifest.write_text(json.dumps(dict(base, **change)))
                with self.assertRaises(ValueError):
                    MODULE.load_input_manifest(manifest)
            self.assertEqual(MODULE.load_input_manifest(None), (MODULE.WEBKIT_COMMIT, MODULE.EXPECTED, None))

    def test_exact_pinned_patch_passes_and_changed_bytes_fail(self):
        base = SCRIPT.parents[1] / "docs/evidence/third-party/webkit-v16-relink-candidate-20261020"
        pinned = base / "webkit-v16-source-modifications.patch"
        self.assertEqual(MODULE.check_pinned_file(pinned, "patch", MODULE.EXPECTED["patch"])["status"], "pass")
        self.assertEqual(MODULE.check_pinned_file(base / "BUILD-CONFIG.json", "buildConfig",
                                                  MODULE.EXPECTED["buildConfig"])["status"], "pass")
        with tempfile.TemporaryDirectory() as tmp:
            wrong = Path(tmp) / "changed.patch"
            wrong.write_text("different\n")
            self.assertEqual(MODULE.check_pinned_file(wrong, "patch", MODULE.EXPECTED["patch"])["status"], "mismatch")

    def test_missing_source_markers_and_built_layout_are_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertEqual(MODULE.check_source_tree(root)["status"], "missing")
            for marker in MODULE.SOURCE_MARKERS:
                entry = root / marker
                entry.parent.mkdir(parents=True, exist_ok=True)
                if marker.endswith("build-webkit"):
                    entry.touch()
                else:
                    entry.mkdir()
            self.assertEqual(MODULE.check_source_tree(root)["status"], "pass")
            self.assertEqual(MODULE.check_frameworks(root)["status"], "missing")
            image = root / "WebKit.framework/Versions/A/WebKit"
            image.parent.mkdir(parents=True)
            image.touch()
            (image.parent / "XPCServices").mkdir()
            report = MODULE.check_frameworks(root)
            self.assertEqual(report["status"], "pass")
            self.assertIn("unverified", report["note"])

    def test_manager_team_mismatch_fails_without_signing(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Recipient.app"
            info = app / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "app.example.recipient"}))
            observed = subprocess.CompletedProcess([], 0, "", "TeamIdentifier=A1B2C3D4E5\n")
            with patch.object(MODULE, "run_readonly", return_value=observed) as command:
                self.assertEqual(MODULE.check_manager(app, "B1C2D3E4F5")["status"], "mismatch")
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[0][:2], ["/usr/bin/codesign", "-dv"])

    def test_publisher_team_cannot_satisfy_independent_recipient(self):
        args = argparse.Namespace(recipient_team=MODULE.PUBLISHER_TEAM, webkit_archive=None,
                                  neantik_archive=None,
                                  patch=None, build_config=None, source_tree=None,
                                  built_frameworks=None, manager_app=None, identity_sha1=None)
        with patch.object(MODULE, "check_toolchain", return_value={"status": "pass"}):
            report = MODULE.inspect(args)
        self.assertEqual(report["checks"]["recipientTeam"]["status"], "mismatch")
        self.assertFalse(report["recipientPackagingInputsPresent"])
        self.assertFalse(report["completeBuildInputsEstablished"])
        self.assertEqual(report["checks"]["completeDependencyInputs"]["status"], "unresolved")
        self.assertFalse(report["recipientRelinkProved"])
        self.assertFalse(report["licenseOrSourceOfferQualified"])

    def test_identity_check_only_matches_requested_fingerprint_and_team(self):
        sha = "A" * 40
        output = f'  1) {sha} "Developer ID Application: Recipient (B1C2D3E4F5)"\n'
        observed = subprocess.CompletedProcess([], 0, output, "")
        with patch.object(MODULE, "run_readonly", return_value=observed):
            self.assertEqual(MODULE.check_identity(sha, "B1C2D3E4F5")["status"], "pass")
            self.assertEqual(MODULE.check_identity(sha, "A1B2C3D4E5")["status"], "mismatch")
        self.assertEqual(MODULE.check_identity("not-a-sha", "B1C2D3E4F5")["status"], "mismatch")


if __name__ == "__main__":
    unittest.main()
