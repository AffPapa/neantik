from __future__ import annotations

import datetime as dt
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts" / "verify-direct-provisioning-profile.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_direct_provisioning_profile", VERIFIER
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

TEAM_ID = "H6VGU2M6JD"
BUNDLE_ID = "app.neantik.desktop"
APPLICATION_ID = f"{TEAM_ID}.{BUNDLE_ID}"


def valid_profile() -> dict[str, object]:
    return {
        "UUID": "00000000-0000-0000-0000-000000000000",
        "Name": "NeAntik Developer ID",
        "ExpirationDate": dt.datetime(2099, 1, 1),
        "TeamIdentifier": [TEAM_ID],
        "Platform": ["OSX"],
        "ProvisionsAllDevices": True,
        "Entitlements": {
            "com.apple.application-identifier": APPLICATION_ID,
            "com.apple.developer.team-identifier": TEAM_ID,
            "keychain-access-groups": [APPLICATION_ID],
        },
    }


class DirectProvisioningProfileTests(unittest.TestCase):
    def validate(self, profile: dict[str, object]) -> None:
        MODULE.validate_profile_payload(
            profile,
            bundle_id=BUNDLE_ID,
            team_id=TEAM_ID,
            application_id=APPLICATION_ID,
            now=dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc),
        )

    def test_accepts_exact_developer_id_distribution_profile(self) -> None:
        self.validate(valid_profile())

    def test_accepts_apple_team_wildcard_keychain_authorization(self) -> None:
        profile = valid_profile()
        entitlements = dict(profile["Entitlements"])
        entitlements["keychain-access-groups"] = [f"{TEAM_ID}.*"]
        profile["Entitlements"] = entitlements
        self.validate(profile)

    def test_rejects_expired_profile(self) -> None:
        profile = valid_profile()
        profile["ExpirationDate"] = dt.datetime(2020, 1, 1)
        with self.assertRaisesRegex(MODULE.ProvisioningProfileError, "expired"):
            self.validate(profile)

    def test_rejects_development_or_ad_hoc_profile(self) -> None:
        profile = valid_profile()
        profile["ProvisionsAllDevices"] = False
        profile["ProvisionedDevices"] = ["device"]
        with self.assertRaisesRegex(
            MODULE.ProvisioningProfileError, "Developer ID distribution"
        ):
            self.validate(profile)

    def test_rejects_wrong_keychain_group(self) -> None:
        profile = valid_profile()
        profile["Entitlements"] = {
            "com.apple.application-identifier": APPLICATION_ID,
            "com.apple.developer.team-identifier": TEAM_ID,
            "keychain-access-groups": [f"{TEAM_ID}.wrong.bundle"],
        }
        with self.assertRaisesRegex(
            MODULE.ProvisioningProfileError, "Keychain access group"
        ):
            self.validate(profile)

    def test_rejects_foreign_team_wildcard_keychain_group(self) -> None:
        profile = valid_profile()
        entitlements = dict(profile["Entitlements"])
        entitlements["keychain-access-groups"] = ["WRONGTEAM.*"]
        profile["Entitlements"] = entitlements
        with self.assertRaisesRegex(
            MODULE.ProvisioningProfileError, "Keychain access group"
        ):
            self.validate(profile)

    def test_rejects_debugging_entitlement(self) -> None:
        profile = valid_profile()
        entitlements = dict(profile["Entitlements"])
        entitlements["get-task-allow"] = True
        profile["Entitlements"] = entitlements
        with self.assertRaisesRegex(
            MODULE.ProvisioningProfileError, "debugging entitlement"
        ):
            self.validate(profile)

    def test_source_entitlements_are_exact(self) -> None:
        MODULE.validate_source_entitlements(
            {
                "com.apple.application-identifier": APPLICATION_ID,
                "com.apple.developer.team-identifier": TEAM_ID,
                "keychain-access-groups": [APPLICATION_ID],
            },
            bundle_id=BUNDLE_ID,
            team_id=TEAM_ID,
            application_id=APPLICATION_ID,
        )
        with self.assertRaisesRegex(
            MODULE.ProvisioningProfileError, "do not match"
        ):
            MODULE.validate_source_entitlements(
                {
                    "com.apple.application-identifier": APPLICATION_ID,
                    "com.apple.developer.team-identifier": TEAM_ID,
                    "keychain-access-groups": [APPLICATION_ID],
                    "get-task-allow": True,
                },
                bundle_id=BUNDLE_ID,
                team_id=TEAM_ID,
                application_id=APPLICATION_ID,
            )


if __name__ == "__main__":
    unittest.main()
