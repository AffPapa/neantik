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
