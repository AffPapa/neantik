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
TEST_WEBKIT_COMMIT = "a" * 40
TEST_EXPECTED = {name: char * 64 for name, char in zip(
    ("webkitArchive", "neantikArchive", "patch", "buildConfig"), "1234")}


def write_manifest(root: Path, hashes: dict[str, str] | None = None) -> Path:
    values = dict(TEST_EXPECTED if hashes is None else hashes)
    path = root / "pins.json"
    path.write_text(json.dumps({"schemaVersion": 1,
                                "pinnedWebKitCommit": TEST_WEBKIT_COMMIT,
                                "expectedSHA256": values}))
    return path


class RecipientPreflightTests(unittest.TestCase):
    def test_new_hash_manifest_checks_new_archive_without_claiming_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "new-source.tar.zst"
            source.write_bytes(b"new source-only archive")
            hashes = dict(TEST_EXPECTED, neantikArchive=hashlib.sha256(source.read_bytes()).hexdigest())
            manifest = write_manifest(root, hashes)
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
            base = {"schemaVersion": 1, "pinnedWebKitCommit": TEST_WEBKIT_COMMIT,
                    "expectedSHA256": dict(TEST_EXPECTED)}
            for change in ({"completeBuildInputsEstablished": True},
                           {"schemaVersion": True},
                           {"expectedSHA256": dict(TEST_EXPECTED, neantikArchive="0" * 63)}):
                manifest.write_text(json.dumps(dict(base, **change)))
                with self.assertRaises(ValueError):
                    MODULE.load_input_manifest(manifest)
            with self.assertRaises(ValueError):
                MODULE.load_input_manifest(None)

    def test_exact_pinned_patch_passes_and_changed_bytes_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pinned = root / "patch"
            config = root / "BUILD-CONFIG.json"
            pinned.write_bytes(b"exact patch fixture")
            config.write_bytes(b"exact config fixture")
            self.assertEqual(MODULE.check_pinned_file(pinned, "patch",
                                                      hashlib.sha256(pinned.read_bytes()).hexdigest())["status"], "pass")
            self.assertEqual(MODULE.check_pinned_file(config, "buildConfig",
                                                      hashlib.sha256(config.read_bytes()).hexdigest())["status"], "pass")
            wrong = root / "changed.patch"
            wrong.write_text("different\n")
            self.assertEqual(MODULE.check_pinned_file(wrong, "patch",
                                                      hashlib.sha256(pinned.read_bytes()).hexdigest())["status"], "mismatch")

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

    def test_same_team_is_allowed_and_independent_team_is_optional(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = argparse.Namespace(input_manifest=write_manifest(Path(tmp)),
                                      recipient_team=MODULE.PUBLISHER_TEAM, webkit_archive=None,
                                      neantik_archive=None, patch=None, build_config=None,
                                      source_tree=None, built_frameworks=None, manager_app=None,
                                      identity_sha1=None)
            with patch.object(MODULE, "check_toolchain", return_value={"status": "pass"}):
                report = MODULE.inspect(args)
        self.assertEqual(report["checks"]["expectedSigningTeam"]["status"], "pass")
        self.assertEqual(report["checks"]["independentTeamAssurance"]["status"], "same-team-only")
        self.assertFalse(report["recipientPackagingInputsPresent"])
        self.assertFalse(report["completeBuildInputsEstablished"])
        self.assertEqual(report["checks"]["completeDependencyInputs"]["status"], "unresolved")
        self.assertFalse(report["recipientRelinkProved"])
        self.assertFalse(report["licenseOrSourceOfferQualified"])

    def test_preflight_exit_does_not_claim_complete_source_offer(self):
        report = {"knownPinnedInputsPresent": True,
                  "completeBuildInputsEstablished": False,
                  "recipientRelinkProved": False,
                  "licenseOrSourceOfferQualified": False}
        self.assertEqual(MODULE.exit_code(report), 0)
        report["knownPinnedInputsPresent"] = False
        self.assertEqual(MODULE.exit_code(report), 2)

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
