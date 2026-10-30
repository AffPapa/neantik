import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_macos_profile_signer import (
    ProfileVerificationError,
    extract_signed_entitlements,
    validate_profile_contract,
)


TEAM = "H6VGU2M6JD"
BUNDLE = "app.neantik.desktop.dev"
APP_ID = f"{TEAM}.{BUNDLE}"
CURRENT_SIGNER = bytes.fromhex("11" * 20)
OLD_SIGNER = bytes.fromhex("22" * 20)


def make_profile(certificates=None):
    return {
        "UUID": "qa-profile-test",
        "Name": "NeAntik QA test",
        "TeamIdentifier": [TEAM],
        "DeveloperCertificates": certificates if certificates is not None else [CURRENT_SIGNER],
        "Entitlements": {
            "com.apple.application-identifier": APP_ID,
            "com.apple.developer.team-identifier": TEAM,
            "keychain-access-groups": [f"{TEAM}.*"],
        },
    }


def make_entitlements():
    return {
        "com.apple.application-identifier": APP_ID,
        "com.apple.developer.team-identifier": TEAM,
        "keychain-access-groups": [APP_ID],
    }


class VerifyMacOSProfileSignerTests(unittest.TestCase):
    def validate(self, profile=None, entitlements=None, signer=None):
        return validate_profile_contract(
            bundle_id=BUNDLE,
            signing_identifier=BUNDLE,
            signing_team=TEAM,
            signing_certificate_sha1=hashlib.sha1(signer or CURRENT_SIGNER).hexdigest(),
            signing_entitlements=entitlements or make_entitlements(),
            profile=profile or make_profile(),
        )

    def test_matching_signer_and_dev_profile_pass(self):
        result = self.validate()
        self.assertEqual(result["status"], "PASS")
        self.assertTrue(result["profileIncludesSigningCertificate"])

    def test_profile_bound_signer_without_explicit_entitlements_passes(self):
        result = self.validate(entitlements={})
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["applicationIdentifier"], APP_ID)

    def test_signed_application_identifier_mismatch_is_rejected(self):
        entitlements = make_entitlements()
        entitlements["com.apple.application-identifier"] = f"{TEAM}.app.other"
        with self.assertRaisesRegex(ProfileVerificationError, "signed_application_identifier_mismatch"):
            self.validate(entitlements=entitlements)

    def test_signed_team_mismatch_is_rejected(self):
        entitlements = make_entitlements()
        entitlements["com.apple.developer.team-identifier"] = "OTHERTEAM12"
        with self.assertRaisesRegex(ProfileVerificationError, "signed_team_mismatch"):
            self.validate(entitlements=entitlements)

    def test_wrong_certificate_is_rejected_even_when_team_and_bundle_match(self):
        with self.assertRaisesRegex(ProfileVerificationError, "signing_certificate_not_in_profile"):
            self.validate(profile=make_profile([OLD_SIGNER]))

    def test_wrong_bundle_identifier_is_rejected(self):
        profile = make_profile()
        profile["Entitlements"]["com.apple.application-identifier"] = f"{TEAM}.app.other"
        with self.assertRaisesRegex(ProfileVerificationError, "profile_application_identifier_mismatch"):
            self.validate(profile=profile)

    def test_wrong_team_is_rejected(self):
        profile = make_profile()
        profile["TeamIdentifier"] = ["OTHERTEAM12"]
        with self.assertRaisesRegex(ProfileVerificationError, "profile_team_mismatch"):
            self.validate(profile=profile)

    def test_disallowed_keychain_group_is_rejected(self):
        profile = make_profile()
        profile["Entitlements"]["keychain-access-groups"] = [f"{TEAM}.app.production"]
        with self.assertRaisesRegex(ProfileVerificationError, "profile_keychain_access_groups_mismatch"):
            self.validate(profile=profile)

    def test_codesign_extract_uses_documented_stdout_path_and_accepts_empty_payload(self):
        from unittest.mock import patch
        import subprocess

        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=b"", stderr=b""
        )
        with patch("verify_macos_profile_signer.subprocess.run", return_value=completed) as run:
            self.assertEqual(extract_signed_entitlements(Path("qa.app")), {})
        self.assertEqual(run.call_args.args[0], [
            "/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", "qa.app"
        ])


if __name__ == "__main__":
    unittest.main()
