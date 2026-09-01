import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-direct-telemetry-disabled.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_direct_telemetry_disabled",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DirectTelemetryDisabledTests(unittest.TestCase):
    def test_accepts_disabled_identifier_free_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = make_project(Path(temporary))
            MODULE.verify(root)

    def test_rejects_any_telemetry_configuration_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = make_project(Path(temporary))
            info_path = root / "Resources/Info.plist"
            with info_path.open("wb") as file:
                plistlib.dump({"NeAntikTelemetryEndpoint": ""}, file)
            with self.assertRaisesRegex(
                MODULE.DirectTelemetryError,
                "configuration keys",
            ):
                MODULE.verify(root)

    def test_rejects_dormant_telemetry_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = make_project(Path(temporary))
            source = root / "Sources/NeAntik/Telemetry.swift"
            source.write_text("struct TelemetryController {}", encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.DirectTelemetryError,
                "telemetry implementation",
            ):
                MODULE.verify(root)

    def test_rejects_missing_source_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = make_project(Path(temporary))
            (root / "Sources/NeAntik").rmdir()
            with self.assertRaisesRegex(
                MODULE.DirectTelemetryError,
                "source directory is missing",
            ):
                MODULE.verify(root)


def make_project(root: Path) -> Path:
    resources = root / "Resources"
    resources.mkdir(parents=True)
    with (resources / "Info.plist").open("wb") as file:
        plistlib.dump({}, file)
    with (resources / "PrivacyInfo.xcprivacy").open("wb") as file:
        plistlib.dump(
            {
                "NSPrivacyTracking": False,
                "NSPrivacyCollectedDataTypes": [],
            },
            file,
        )
    (root / "Sources/NeAntik").mkdir(parents=True)
    return root


if __name__ == "__main__":
    unittest.main()
