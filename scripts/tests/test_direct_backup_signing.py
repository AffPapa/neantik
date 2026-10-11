import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import direct_backup_signing as signing
from direct_provisioning_contract import ContractError, PRODUCTION


class DirectBackupSigningTests(unittest.TestCase):
    def app(self, root, **extra):
        app = root / "Owned.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": PRODUCTION, **extra}))
        return app

    def test_selection_requires_explicit_profile_and_same_certificate(self):
        self.assertFalse(signing.validate_selection("0", None, "-"))
        self.assertTrue(signing.validate_selection("1", "/synthetic/profile", signing.CERTIFICATE))
        for enabled, profile, identity in [("yes", None, signing.CERTIFICATE), ("1", None, signing.CERTIFICATE),
                                           ("0", "/synthetic/profile", signing.CERTIFICATE),
                                           ("1", "/synthetic/profile", "-"),
                                           ("1", "/synthetic/profile", "0" * 40)]:
            with self.subTest(enabled=enabled, identity=identity):
                with self.assertRaises(ContractError): signing.validate_selection(enabled, profile, identity)

    def test_capability_profile_identity_and_metadata_negatives(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = self.app(Path(directory))
            self.assertFalse(signing.capability_state(app))
            info_path = app / "Contents/Info.plist"
            base = plistlib.loads(info_path.read_bytes())
            for extra in [{signing.CAPABILITY: 1}, {signing.CAPABILITY: "true"}, {signing.CAPABILITY: True},
                          {"CFBundleIdentifier": "app.neantik.desktop.dev"},
                          {"NeAntikBackupQualificationRunID": "synthetic"}]:
                info_path.write_bytes(plistlib.dumps({**base, **extra}))
                with self.assertRaises(ContractError): signing.capability_state(app)
            info_path.write_bytes(plistlib.dumps(base))
            embedded = app / "Contents/embedded.provisionprofile"
            embedded.write_bytes(b"synthetic, not authenticated")
            with self.assertRaises(ContractError): signing.capability_state(app)
            info_path.write_bytes(plistlib.dumps({**base, signing.CAPABILITY: True}))
            self.assertTrue(signing.capability_state(app))  # selection only, not CMS proof
            embedded.unlink(); embedded.symlink_to(info_path)
            with self.assertRaises(OSError): signing.capability_state(app)

    def test_legacy_signing_keeps_exact_old_entitlements(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = self.app(Path(directory)); calls = []
            signing.sign_manager(app, signing.CERTIFICATE, {}, calls.append)
            self.assertEqual(len(calls), 1)
            self.assertIn("--timestamp", calls[0])
            self.assertTrue(calls[0][calls[0].index("--entitlements") + 1].endswith("runtime/neantik-direct-entitlements.plist"))
            self.assertFalse(signing.capability_state(app))

    def test_invalid_profile_refuses_before_any_owned_staging_mutation(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = self.app(Path(directory), **{signing.CAPABILITY: True})
            embedded = app / "Contents/embedded.provisionprofile"; embedded.write_bytes(b"existing synthetic profile")
            info_before = (app / "Contents/Info.plist").read_bytes()
            def refused(arguments): raise subprocess.CalledProcessError(65, "redacted synthetic refusal")
            with self.assertRaises(subprocess.SubprocessError):
                signing.sign_manager(app, signing.CERTIFICATE,
                    {"NEANTIK_BROWSER_DATA_BACKUP_ENABLED": "1", "NEANTIK_DIRECT_PROVISIONING_PROFILE": "/synthetic/profile"}, refused)
            self.assertEqual(embedded.read_bytes(), b"existing synthetic profile")
            self.assertEqual((app / "Contents/Info.plist").read_bytes(), info_before)

    def test_preparation_signature_and_postcheck_order_and_no_fallback(self):
        for fail_postcheck in [False, True]:
            with self.subTest(fail_postcheck=fail_postcheck), tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
                root = Path(directory); app = self.app(root)
                source_profile = root / "source-profile"; source_profile.write_bytes(b"synthetic authenticated fixture")
                embedded = app / "Contents/embedded.provisionprofile"; embedded.write_bytes(b"old owned staged profile")
                calls = []
                def fake_run(arguments):
                    calls.append(arguments)
                    if "--output-entitlements" in arguments:
                        self.assertFalse(embedded.exists())
                        Path(arguments[arguments.index("--output-entitlements") + 1]).write_bytes(b"synthetic claims")
                        embedded.write_bytes(source_profile.read_bytes())
                    elif arguments[0] == "/usr/bin/codesign":
                        self.assertTrue(signing.capability_state(app))
                    elif "--app" in arguments and fail_postcheck:
                        raise subprocess.CalledProcessError(65, "postcheck")
                env = {"NEANTIK_BROWSER_DATA_BACKUP_ENABLED": "1", "NEANTIK_DIRECT_PROVISIONING_PROFILE": str(source_profile)}
                if fail_postcheck:
                    with self.assertRaises(subprocess.SubprocessError): signing.sign_manager(app, signing.CERTIFICATE, env, fake_run)
                else: signing.sign_manager(app, signing.CERTIFICATE, env, fake_run)
                self.assertEqual(len(calls), 4)
                self.assertNotIn("--app", calls[0])
                self.assertIn("--output-entitlements", calls[1])
                self.assertEqual(calls[2][0], "/usr/bin/codesign")
                self.assertIn("--app", calls[3])
                self.assertNotIn("--output-entitlements", calls[3])
                self.assertEqual(source_profile.read_bytes(), b"synthetic authenticated fixture")

    def test_provisioned_candidate_never_silently_downgrades(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = self.app(Path(directory), **{signing.CAPABILITY: True})
            (app / "Contents/embedded.provisionprofile").write_bytes(b"synthetic")
            calls = []
            with self.assertRaises(ContractError): signing.sign_manager(app, signing.CERTIFICATE, {}, calls.append)
            self.assertEqual(calls, [])

    def test_hardlink_swap_during_profile_preparation_never_truncates_other_file(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory); app = self.app(root); info_path = app / "Contents/Info.plist"
            other = root / "preserve-other-plist"; other.write_bytes(info_path.read_bytes()); original = other.read_bytes()
            calls = []
            def swap(arguments):
                calls.append(arguments)
                if "--output-entitlements" in arguments:
                    info_path.unlink(); info_path.hardlink_to(other)
            with self.assertRaises(ContractError):
                signing.sign_manager(app, signing.CERTIFICATE,
                    {"NEANTIK_BROWSER_DATA_BACKUP_ENABLED": "1", "NEANTIK_DIRECT_PROVISIONING_PROFILE": "/synthetic/profile"}, swap)
            self.assertEqual(other.read_bytes(), original)
            self.assertFalse(any(call[0] == "/usr/bin/codesign" for call in calls))

    def test_capability_write_fault_retains_original_and_cleans_temporary_output(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = self.app(Path(directory)); info_path = app / "Contents/Info.plist"; original = info_path.read_bytes()
            info = plistlib.loads(original); info[signing.CAPABILITY] = True
            with patch.object(signing.os, "fsync", side_effect=OSError("synthetic disk-full")):
                with self.assertRaises(OSError): signing.seal_capability(app, info, original)
            self.assertEqual(info_path.read_bytes(), original)
            self.assertEqual(list((app / "Contents").glob(".backup-capability-*")), [])


if __name__ == "__main__": unittest.main()
