import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-direct-branding-residue.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_direct_branding_residue",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write_app(root: Path, *, manager_name: str = "NeAntik") -> Path:
    app = root / "NeAntik.app"
    contents = app / "Contents"
    executable = contents / "MacOS" / "NeAntik"
    runtime = (
        contents
        / "Resources"
        / "NeAntik Browser.app"
        / "Contents"
        / "Frameworks"
        / "NeVision Browser Framework.framework"
    )
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"clean manager")
    runtime.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(
            {
                "CFBundleDisplayName": manager_name,
                "CFBundleExecutable": "NeAntik",
                "CFBundleIdentifier": "app.neantik.desktop",
                "CFBundleName": "NeAntik",
                "CFBundleSignature": "NANT",
            },
            file,
        )
    (contents / "PkgInfo").write_bytes(b"APPLNANT")
    privacy = contents / "Resources" / "PrivacyInfo.xcprivacy"
    with privacy.open("wb") as file:
        plistlib.dump({}, file)
    return app


class VerifyDirectBrandingResidueTests(unittest.TestCase):
    def test_separates_clean_manager_from_compiled_runtime_residue(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = MODULE.inspect_app(write_app(Path(temporary)))

        self.assertTrue(result["publicManagerQualified"])
        self.assertFalse(result["strictRuntimeBrandingQualified"])
        self.assertEqual(result["legacyRuntimeBrandingCount"], 1)

    def test_rejects_public_manager_legacy_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = MODULE.inspect_app(
                write_app(Path(temporary), manager_name="NeVision")
            )

        self.assertFalse(result["publicManagerQualified"])
        self.assertTrue(
            any("CFBundleDisplayName" in issue for issue in result["publicManagerIssues"])
        )


if __name__ == "__main__":
    unittest.main()
