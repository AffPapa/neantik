from __future__ import annotations

import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "verify-direct-update-policy.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_direct_update_policy",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DirectUpdatePolicyTests(unittest.TestCase):
    def test_packaged_configuration_must_equal_approved_metadata(self) -> None:
        base = self.base_info()
        changes = {
            "NeAntikUpdateChannelEnabled": True,
            "NeAntikUpdateAutoDownload": True,
            "NeAntikUpdateManifestURL": "https://browser.free/update.json",
            "NeAntikUpdatePublicKeyID": "different-key",
            "NeAntikUpdatePublicKeyBase64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        }
        with tempfile.TemporaryDirectory() as temporary:
            expected = Path(temporary)/"Approved.plist"
            actual = Path(temporary)/"Candidate.plist"
            expected.write_bytes(plistlib.dumps(base))
            actual.write_bytes(plistlib.dumps(base))
            self.assertIn("disabled-manual", MODULE.verify(info_plist=actual, expected_info_plist=expected))
            for key,value in changes.items():
                for candidate in [dict(base, **{key:value}), {k:v for k,v in base.items() if k != key}]:
                    with self.subTest(key=key, missing=key not in candidate):
                        actual.write_bytes(plistlib.dumps(candidate))
                        with self.assertRaisesRegex(MODULE.UpdatePolicyError, "does not match approved"):
                            MODULE.verify(info_plist=actual, expected_info_plist=expected)

    def test_valid_enabled_candidate_cannot_silently_change_channel_or_key(self) -> None:
        base = self.base_info()
        base.update(NeAntikUpdateChannelEnabled=True,
                    NeAntikUpdateManifestURL="https://browser.free/update.json",
                    NeAntikUpdatePublicKeyID="owned-public-key",
                    NeAntikUpdatePublicKeyBase64="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        with tempfile.TemporaryDirectory() as temporary:
            expected,actual = Path(temporary)/"Approved.plist",Path(temporary)/"Candidate.plist"
            expected.write_bytes(plistlib.dumps(base)); actual.write_bytes(plistlib.dumps(base))
            self.assertIn("configured", MODULE.verify(info_plist=actual, expected_info_plist=expected))
            for key,value in {
                "NeAntikUpdateManifestURL":"https://affpapa.org/neantik/update.json",
                "NeAntikUpdatePublicKeyID":"different-valid-key",
                "NeAntikUpdatePublicKeyBase64":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
            }.items():
                with self.subTest(key=key):
                    candidate = dict(base, **{key:value}); actual.write_bytes(plistlib.dumps(candidate))
                    self.assertIn("configured", MODULE.verify(info_plist=actual))
                    with self.assertRaises(MODULE.UpdatePolicyError):
                        MODULE.verify(info_plist=actual, expected_info_plist=expected)

    def test_packaged_integer_false_is_not_boolean_false(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected,actual = Path(temporary)/"Approved.plist",Path(temporary)/"Candidate.plist"
            expected.write_bytes(plistlib.dumps(self.base_info()))
            for key in ["NeAntikUpdateChannelEnabled", "NeAntikUpdateAutoDownload"]:
                candidate = dict(self.base_info(), **{key:0}); actual.write_bytes(plistlib.dumps(candidate))
                with self.assertRaises(MODULE.UpdatePolicyError):
                    MODULE.verify(info_plist=actual, expected_info_plist=expected)

    def test_current_direct_policy_is_disabled_and_fail_closed(self) -> None:
        message = MODULE.verify()

        self.assertIn("disabled-manual", message)
        self.assertIn("automatic download disabled", message)

    def test_rejects_disabled_policy_with_partial_key_material(self) -> None:
        info = self.base_info()
        info["NeAntikUpdatePublicKeyID"] = "release-2026"

        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump(info, handle)
            with self.assertRaises(MODULE.UpdatePolicyError):
                MODULE.verify(info_plist=plist_path)

    def test_rejects_automatic_download(self) -> None:
        info = self.base_info()
        info["NeAntikUpdateAutoDownload"] = True

        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump(info, handle)
            with self.assertRaises(MODULE.UpdatePolicyError):
                MODULE.verify(info_plist=plist_path)

    def test_accepts_complete_future_public_key_configuration(self) -> None:
        info = self.base_info()
        info.update(
            {
                "NeAntikUpdateChannelEnabled": True,
                "NeAntikUpdateManifestURL":
                    "https://affpapa.org/neantik/update.json",
                "NeAntikUpdatePublicKeyID": "release-2026",
                "NeAntikUpdatePublicKeyBase64":
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            }
        )

        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump(info, handle)
            message = MODULE.verify(info_plist=plist_path)

        self.assertIn("configured", message)

    def test_rejects_credentialed_manifest_url(self) -> None:
        info = self.base_info()
        info.update(
            {
                "NeAntikUpdateChannelEnabled": True,
                "NeAntikUpdateManifestURL":
                    "https://user:secret@example.com/update.json",
                "NeAntikUpdatePublicKeyID": "release-2026",
                "NeAntikUpdatePublicKeyBase64":
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            }
        )

        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump(info, handle)
            with self.assertRaises(MODULE.UpdatePolicyError):
                MODULE.verify(info_plist=plist_path)

    def test_rejects_unapproved_manifest_host(self) -> None:
        info = self.base_info()
        info.update(
            {
                "NeAntikUpdateChannelEnabled": True,
                "NeAntikUpdateManifestURL":
                    "https://updates.example.net/update.json",
                "NeAntikUpdatePublicKeyID": "release-2026",
                "NeAntikUpdatePublicKeyBase64":
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            }
        )

        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump(info, handle)
            with self.assertRaises(MODULE.UpdatePolicyError):
                MODULE.verify(info_plist=plist_path)

    def test_rejects_malformed_manifest_url_without_crashing(self) -> None:
        info = self.base_info()
        info.update(
            {
                "NeAntikUpdateChannelEnabled": True,
                "NeAntikUpdateManifestURL": "https://[broken/update.json",
                "NeAntikUpdatePublicKeyID": "release-2026",
                "NeAntikUpdatePublicKeyBase64":
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            }
        )

        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump(info, handle)
            with self.assertRaises(MODULE.UpdatePolicyError):
                MODULE.verify(info_plist=plist_path)

    @staticmethod
    def base_info() -> dict[str, object]:
        return {
            "NeAntikUpdateChannelEnabled": False,
            "NeAntikUpdateAutoDownload": False,
            "NeAntikUpdateManifestURL": "",
            "NeAntikUpdatePublicKeyID": "",
            "NeAntikUpdatePublicKeyBase64": "",
        }


if __name__ == "__main__":
    unittest.main()
