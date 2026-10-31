import copy
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import direct_provisioning_contract as contract
spec = importlib.util.spec_from_file_location("provisioning_cli", SCRIPTS / "verify-direct-provisioning-contract.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class DirectProvisioningTests(unittest.TestCase):
    def test_cli_selector_alone_does_not_authorize_a_certificate(self):
        profile, selector = self.fixture()
        self.assertEqual(self.validate(profile, selector), contract.exact_claims(contract.QA))
        profile['DeveloperCertificates'] = [b'foreign certificate with the same claimed selector']
        with self.assertRaisesRegex(contract.ContractError, 'certificate differs'):
            self.validate(profile, selector)
        with self.assertRaises(ValueError):
            contract.signing.certificate_sha256_for_selector('0' * 40)
        self.assertEqual(len(contract.signing.certificate_sha256_for_selector(selector)), 64)

    def test_media_purpose_strings_and_exact_grants(self):
        self.assertEqual(contract.media_claims({}), {})  # Old immutable apps remain supported.
        info = {"NSCameraUsageDescription": "User-approved website camera",
                "NSMicrophoneUsageDescription": "User-approved website microphone"}
        expected = {"com.apple.security.device.camera": True, "com.apple.security.device.audio-input": True}
        self.assertEqual(contract.media_claims(info), expected)
        self.assertEqual(contract.media_claims({"NeAntikWebKitMediaPolicyEnabled": False}), {})
        self.assertEqual(contract.media_claims({**info, "NeAntikWebKitMediaPolicyEnabled": True}), expected)
        for bad in [{"NeAntikWebKitMediaPolicyEnabled": True}, {"NeAntikWebKitMediaPolicyEnabled": 1},
                    {**info, "NeAntikWebKitMediaPolicyEnabled": False}]:
            with self.assertRaises(contract.ContractError): contract.media_claims(bad)
        for broken in [{"NSCameraUsageDescription": "camera"},
                       {**info, "NSMicrophoneUsageDescription": " "},
                       {**info, "NSCameraUsageDescription": False}]:
            with self.assertRaises(contract.ContractError): contract.media_claims(broken)
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = Path(directory) / "QA.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": contract.QA, **info}))
            output = Path(directory) / "claims.plist"
            cli.prepare_outputs(app, output, b"own synthetic profile", contract.QA)
            self.assertEqual(plistlib.loads(output.read_bytes()), {**contract.exact_claims(contract.QA), **expected})
        profile, sha = self.fixture()
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = Path(directory) / "QA.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": contract.QA, **info}))
            (app / "Contents/embedded.provisionprofile").write_bytes(b"own synthetic profile")
            signed = {"entitlements": {**contract.exact_claims(contract.QA), **expected},
                      "certificate": profile["DeveloperCertificates"][0], "hardenedRuntime": True}
            with patch.object(contract, "authenticated_profile", return_value=profile), patch.object(contract, "security_result", return_value=signed):
                self.assertEqual(contract.verify_app(Path("/helper"), app, contract.QA, sha), "provisioned")
                foreign = b"another profile member cannot claim the selected signing identity"
                profile["DeveloperCertificates"].append(foreign)
                with patch.object(contract, "security_result", return_value={**signed, "certificate": foreign}):
                    with self.assertRaisesRegex(contract.ContractError, "Actual signed certificate"):
                        contract.verify_app(Path("/helper"), app, contract.QA, sha)
                for key in expected:
                    broken = {**signed, "entitlements": {k: v for k, v in signed["entitlements"].items() if k != key}}
                    with patch.object(contract, "security_result", return_value=broken):
                        with self.assertRaises(contract.ContractError): contract.verify_app(Path("/helper"), app, contract.QA, sha)

    def fixture(self):
        certificate = b"synthetic certificate fixture, not runtime trust proof"
        selector = "F" * 40  # An opaque Apple CLI selector, never a trust hash.
        pin = hashlib.sha256(certificate).hexdigest()
        override = patch.dict(contract.signing.APPROVED_CERTIFICATE_SHA256, {selector: pin})
        override.start()
        self.addCleanup(override.stop)
        return {"Platform": ["OSX"], "ProvisionsAllDevices": True,
                "TeamIdentifier": [contract.TEAM], "ApplicationIdentifierPrefix": [contract.TEAM],
                "CreationDate": dt.datetime(2026, 1, 1), "ExpirationDate": dt.datetime(2040, 1, 1),
                "Entitlements": {"com.apple.application-identifier": contract.TEAM + ".*",
                                 "com.apple.developer.team-identifier": contract.TEAM,
                                 "keychain-access-groups": [contract.TEAM + ".*"]},
                "DeveloperCertificates": [certificate]}, selector

    def validate(self, profile, certificate):
        return contract.validate_profile(profile, contract.QA, certificate,
                                         dt.datetime(2026, 10, 11, tzinfo=dt.timezone.utc))

    def test_exact_and_terminal_wildcard_grants(self):
        profile, certificate = self.fixture()
        expected = contract.exact_claims(contract.QA)
        self.assertEqual(self.validate(profile, certificate), expected)
        profile["Entitlements"].update(expected)
        self.assertEqual(self.validate(profile, certificate), expected)
        self.assertEqual(expected["keychain-access-groups"], [contract.TEAM + "." + contract.QA])

    def test_group_wildcard_cannot_replace_app_id_grant(self):
        profile, certificate = self.fixture()
        profile["Entitlements"]["com.apple.application-identifier"] = contract.TEAM + "." + contract.PRODUCTION
        with self.assertRaisesRegex(contract.ContractError, "App ID"):
            self.validate(profile, certificate)

    def test_platform_distribution_team_dates_certificate_and_grant_negatives(self):
        profile, certificate = self.fixture()
        changes = [
            ("Platform", ["iOS", "xrOS", "visionOS"]), ("ProvisionsAllDevices", 1),
            ("ProvisionedDevices", []), ("LocalProvision", True),
            ("TeamIdentifier", ["OTHERTEAM"]), ("ApplicationIdentifierPrefix", ["OTHERTEAM"]),
            ("ExpirationDate", dt.datetime(2025, 1, 1)), ("CreationDate", dt.datetime(2030, 1, 1)),
            ("ExpirationDate", "2040"), ("DeveloperCertificates", []),
            ("DeveloperCertificates", ["not DER bytes"]),
            ("DeveloperCertificates", [b"different valid byte payload"]),
        ]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                changed = copy.deepcopy(profile); changed[key] = value
                with self.assertRaises(contract.ContractError): self.validate(changed, certificate)
        for key, value in [
            ("com.apple.developer.team-identifier", "OTHERTEAM"),
            ("com.apple.application-identifier", contract.TEAM + ".app.neantik.*.qa"),
            ("keychain-access-groups", [contract.TEAM + ".wrong"]),
            ("get-task-allow", True), ("com.apple.security.get-task-allow", True),
            ("get-task-allow", 1), ("com.apple.security.get-task-allow", "false"),
        ]:
            with self.subTest(grant=key):
                changed = copy.deepcopy(profile); changed["Entitlements"][key] = value
                with self.assertRaises(contract.ContractError): self.validate(changed, certificate)
        for sha in ("0" * 40, "malformed"):
            with self.assertRaises(contract.ContractError): self.validate(profile, sha)

    def test_new_output_binding_and_no_overwrite(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory); app = root / "QA.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": contract.QA}))
            entitlements = root / "claims.plist"
            cli.prepare_outputs(app, entitlements, b"authenticated bytes fixture", contract.QA)
            self.assertEqual(plistlib.loads(entitlements.read_bytes()), contract.exact_claims(contract.QA))
            self.assertEqual((app / "Contents/embedded.provisionprofile").read_bytes(), b"authenticated bytes fixture")
            with self.assertRaises(contract.ContractError): cli.prepare_outputs(app, entitlements, b"replacement", contract.QA)
            self.assertEqual((app / "Contents/embedded.provisionprofile").read_bytes(), b"authenticated bytes fixture")

    def test_output_failure_rolls_back_own_first_file(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory); app = root / "QA.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": contract.QA}))
            real_open = cli.os.open
            def failing_open(path, *args, **kwargs):
                if str(path).endswith("embedded.provisionprofile"): raise PermissionError("fixture")
                return real_open(path, *args, **kwargs)
            with patch.object(cli.os, "open", side_effect=failing_open):
                with self.assertRaises(PermissionError): cli.prepare_outputs(app, root / "claims.plist", b"fixture", contract.QA)
            self.assertFalse((root / "claims.plist").exists())
            self.assertFalse((app / "Contents/embedded.provisionprofile").exists())

    def test_symlink_hardlink_fifo_and_oversize_refused(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory); regular = root / "regular"; regular.write_bytes(b"original")
            self.assertEqual(contract.read_regular(regular), b"original")
            link = root / "symlink"; link.symlink_to(regular)
            with self.assertRaises(OSError): contract.read_regular(link)
            hard = root / "hard"; hard.hardlink_to(regular)
            with self.assertRaises(contract.ContractError): contract.read_regular(hard)
            hard.unlink()
            fifo = root / "fifo"; contract.os.mkfifo(fifo)
            with self.assertRaises(contract.ContractError): contract.read_regular(fifo)
            regular.write_bytes(b"x" * (contract.LIMIT + 1))
            with self.assertRaises(contract.ContractError): contract.read_regular(regular)

    def test_signed_claims_and_missing_or_changed_embedded_profile_refused(self):
        profile, sha = self.fixture(); claims = contract.exact_claims(contract.QA)
        signed = {"entitlements": claims, "certificate": profile["DeveloperCertificates"][0], "hardenedRuntime": True}
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = Path(directory) / "QA.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": contract.QA}))
            embedded = app / "Contents/embedded.provisionprofile"; embedded.write_bytes(b"approved")
            with patch.object(contract, "authenticated_profile", return_value=profile), patch.object(contract, "security_result", return_value=signed):
                self.assertEqual(contract.verify_app(Path("/helper"), app, contract.QA, sha, b"approved"), "provisioned")
                bad = copy.deepcopy(signed); bad["entitlements"]["get-task-allow"] = True
                with patch.object(contract, "security_result", return_value=bad):
                    with self.assertRaises(contract.ContractError): contract.verify_app(Path("/helper"), app, contract.QA, sha)
                with self.assertRaises(contract.ContractError): contract.verify_app(Path("/helper"), app, contract.QA, sha, b"other")
                embedded.unlink()
                with self.assertRaises(contract.ContractError): contract.verify_app(Path("/helper"), app, contract.QA, sha, b"approved")
                with self.assertRaises(contract.ContractError): contract.verify_app(Path("/helper"), app, contract.QA, sha)

    def test_profile_replacement_during_signed_code_verification_refused(self):
        profile, sha = self.fixture()
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = Path(directory) / "QA.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": contract.QA}))
            embedded = app / "Contents/embedded.provisionprofile"; embedded.write_bytes(b"approved")
            def replacing(*args):
                embedded.write_bytes(b"replaced")
                return {"entitlements": contract.exact_claims(contract.QA), "certificate": profile["DeveloperCertificates"][0], "hardenedRuntime": True}
            with patch.object(contract, "authenticated_profile", return_value=profile), patch.object(contract, "security_result", side_effect=replacing):
                with self.assertRaisesRegex(contract.ContractError, "changed"):
                    contract.verify_app(Path("/helper"), app, contract.QA, sha)

    def test_invalid_provisioned_signature_never_falls_back_to_legacy(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            app = Path(directory) / "App.app"; (app / "Contents").mkdir(parents=True)
            (app / "Contents/embedded.provisionprofile").write_bytes(b"broken CMS")
            with patch.object(contract, "authenticated_profile", side_effect=contract.ContractError("invalid")), patch.object(contract, "security_result") as signed:
                with self.assertRaises(contract.ContractError): contract.verify_app(Path("/helper"), app, contract.PRODUCTION, "0" * 40)
                signed.assert_not_called()


if __name__ == "__main__": unittest.main()
