import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-apple-device-tuples.py"
SPEC = importlib.util.spec_from_file_location("verify_apple_device_tuples", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

PROJECT_ROOT = Path(__file__).resolve().parents[2]


class AppleDeviceTupleVerifierTests(unittest.TestCase):
    def test_current_sources_match_manifest(self) -> None:
        report = MODULE.verify_consistency(
            manifest_path=PROJECT_ROOT / "runtime" / "apple-device-tuples.json",
            swift_path=PROJECT_ROOT / "Sources" / "NeAntik" / "FingerprintAudit.swift",
            python_path=PROJECT_ROOT / "scripts" / "verify-gui-fingerprint-report.py",
            models_path=PROJECT_ROOT / "Sources" / "NeAntik" / "Models.swift",
        )

        self.assertTrue(report["consistent"])
        self.assertEqual(report["tupleCount"], 11)
        self.assertEqual(report["issues"], [])

    def test_detects_python_tuple_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "apple-device-tuples.json"
            swift = root / "FingerprintAudit.swift"
            python = root / "verify-gui-fingerprint-report.py"
            manifest.write_text(
                (PROJECT_ROOT / "runtime" / "apple-device-tuples.json").read_text(
                    encoding="utf-8"
                ),
                encoding="utf-8",
            )
            swift.write_text(
                (PROJECT_ROOT / "Sources" / "NeAntik" / "FingerprintAudit.swift").read_text(
                    encoding="utf-8"
                ),
                encoding="utf-8",
            )
            python.write_text(
                (
                    PROJECT_ROOT / "scripts" / "verify-gui-fingerprint-report.py"
                )
                .read_text(encoding="utf-8")
                .replace('"M4 Pro", 14', '"M4 Pro", 12', 1),
                encoding="utf-8",
            )

            report = MODULE.verify_consistency(
                manifest_path=manifest,
                swift_path=swift,
                python_path=python,
            )

        self.assertFalse(report["consistent"])
        self.assertTrue(any("Python tuple" in issue for issue in report["issues"]))

    def test_rejects_duplicate_manifest_tuple_ids(self) -> None:
        payload = json.loads(
            (PROJECT_ROOT / "runtime" / "apple-device-tuples.json").read_text(
                encoding="utf-8"
            )
        )
        payload["tuples"][1]["id"] = payload["tuples"][0]["id"]
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "apple-device-tuples.json"
            manifest.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.DeviceTupleError, "duplicate"):
                MODULE.load_manifest(manifest)

    def test_rejects_memory_or_scale_incoherence(self) -> None:
        payload = json.loads(
            (PROJECT_ROOT / "runtime" / "apple-device-tuples.json").read_text(
                encoding="utf-8"
            )
        )
        payload["tuples"][0]["physicalMemoryGB"] = 4
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "apple-device-tuples.json"
            manifest.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.DeviceTupleError,
                "physicalMemoryGB",
            ):
                MODULE.load_manifest(manifest)

        payload["tuples"][0]["physicalMemoryGB"] = 8
        payload["tuples"][0]["deviceScaleFactor"] = 1
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "apple-device-tuples.json"
            manifest.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.DeviceTupleError,
                "deviceScaleFactor",
            ):
                MODULE.load_manifest(manifest)

    def test_detects_identity_catalog_reordering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            models = root / "Models.swift"
            models.write_text(
                (
                    PROJECT_ROOT
                    / "Sources"
                    / "NeAntik"
                    / "Models.swift"
                )
                .read_text(encoding="utf-8")
                .replace(
                    '"macbook-air-m1",\n        "macbook-pro-m1-pro"',
                    '"macbook-pro-m1-pro",\n        "macbook-air-m1"',
                    1,
                ),
                encoding="utf-8",
            )

            report = MODULE.verify_consistency(
                manifest_path=PROJECT_ROOT
                / "runtime"
                / "apple-device-tuples.json",
                swift_path=PROJECT_ROOT
                / "Sources"
                / "NeAntik"
                / "FingerprintAudit.swift",
                python_path=PROJECT_ROOT
                / "scripts"
                / "verify-gui-fingerprint-report.py",
                models_path=models,
            )

        self.assertFalse(report["consistent"])
        self.assertTrue(
            any("identity catalog" in issue for issue in report["issues"])
        )


if __name__ == "__main__":
    unittest.main()
