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

    def test_rejects_endpoint_or_stable_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = make_project(Path(temporary), endpoint="https://example.test")
            with self.assertRaisesRegex(
                MODULE.DirectTelemetryError,
                "endpoint",
            ):
                MODULE.verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = make_project(Path(temporary))
            source = root / "Sources/NeAntik/Telemetry.swift"
            source.write_text("let installationHash = \"x\"", encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.DirectTelemetryError,
                "installationHash",
            ):
                MODULE.verify(root)


def make_project(root: Path, endpoint: str = "") -> Path:
    resources = root / "Resources"
    resources.mkdir(parents=True)
    with (resources / "Info.plist").open("wb") as file:
        plistlib.dump({"NeAntikTelemetryEndpoint": endpoint}, file)
    with (resources / "PrivacyInfo.xcprivacy").open("wb") as file:
        plistlib.dump(
            {
                "NSPrivacyTracking": False,
                "NSPrivacyCollectedDataTypes": [],
            },
            file,
        )
    source = root / "Sources/NeAntik/Telemetry.swift"
    source.parent.mkdir(parents=True)
    source.write_text("struct Payload { let eventID: String }", encoding="utf-8")
    return root


if __name__ == "__main__":
    unittest.main()
