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
    def test_current_direct_policy_is_manual_and_has_no_updater(self) -> None:
        message = MODULE.verify()

        self.assertIn("manual immutable releases only", message)

    def test_rejects_any_dormant_update_configuration_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plist_path = root / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump({"NeAntikUpdateChannelEnabled": False}, handle)
            source_root = root / "Sources/NeAntik"
            source_root.mkdir(parents=True)
            with self.assertRaisesRegex(
                MODULE.UpdatePolicyError,
                "configuration keys",
            ):
                MODULE.verify(
                    info_plist=plist_path,
                    source_root=source_root,
                )

    def test_rejects_dormant_update_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plist_path = root / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump({}, handle)
            source_root = root / "Sources/NeAntik"
            source_root.mkdir(parents=True)
            (source_root / "UpdateManifest.swift").write_text(
                "struct UpdateManifest {}",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.UpdatePolicyError,
                "update implementation",
            ):
                MODULE.verify(
                    info_plist=plist_path,
                    source_root=source_root,
                )

    def test_rejects_missing_source_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plist_path = root / "Info.plist"
            with plist_path.open("wb") as handle:
                plistlib.dump({}, handle)
            with self.assertRaisesRegex(
                MODULE.UpdatePolicyError,
                "source directory is missing",
            ):
                MODULE.verify(
                    info_plist=plist_path,
                    source_root=root / "missing",
                )


if __name__ == "__main__":
    unittest.main()
