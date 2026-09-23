import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-runtime-performance-report.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_runtime_performance_report",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def report(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "schemaVersion": 1,
        "status": "verified",
        "runtimeVersion": "153.0.8010.52",
        "runtimeHash": "a" * 64,
        "generatedAt": "2026-09-23T12:00:00Z",
        "sampleCount": 5,
        "coldStartMs": {"p50": 900, "p95": 1_400},
        "warmStartMs": {"p50": 200, "p95": 450},
        "idleCpuPercent": {"p50": 2.0, "p95": 7.0},
        "idleMemoryMiB": {"p50": 400, "p95": 700},
    }
    value.update(overrides)
    return value


class RuntimePerformanceReportTests(unittest.TestCase):
    def test_verified_report_is_accepted(self) -> None:
        MODULE.validate_report(report())

    def test_manager_style_report_cannot_be_verified(self) -> None:
        value = report(
            runtimeVersion=None,
            runtimeHash=None,
            status="unverified",
            coldStartMs={"p50": None, "p95": None},
            warmStartMs={"p50": None, "p95": None},
            idleCpuPercent={"p50": None, "p95": None},
            idleMemoryMiB={"p50": None, "p95": None},
            sampleCount=0,
        )
        MODULE.validate_report(value)

        value["status"] = "verified"
        with self.assertRaises(MODULE.RuntimePerformanceReportError):
            MODULE.validate_report(value)

        value["status"] = "unverified"
        with self.assertRaisesRegex(
            MODULE.RuntimePerformanceReportError,
            "release mode",
        ):
            MODULE.validate_report(value, require_verified=True)

    def test_budget_regression_rejects_verified_report(self) -> None:
        value = report(
            coldStartMs={"p50": 900, "p95": 3_001}
        )
        with self.assertRaisesRegex(
            MODULE.RuntimePerformanceReportError,
            "budget",
        ):
            MODULE.validate_report(value)

    def test_missing_or_extra_root_key_is_rejected(self) -> None:
        value = report()
        del value["runtimeHash"]
        with self.assertRaises(MODULE.RuntimePerformanceReportError):
            MODULE.validate_report(value)

        value = report(extra="not allowed")
        with self.assertRaises(MODULE.RuntimePerformanceReportError):
            MODULE.validate_report(value)

    def test_duplicate_keys_are_rejected(self) -> None:
        payload = json.dumps(report())[:-1]
        payload += ',"status":"partial"}'
        with tempfile.NamedTemporaryFile(mode="wb") as temporary:
            temporary.write(payload.encode("utf-8"))
            temporary.flush()
            with self.assertRaises(MODULE.RuntimePerformanceReportError):
                MODULE.load_report(temporary.name)

    def test_cli_accepts_stdin_and_rejects_non_utc_report(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "-"],
            input=json.dumps(report()).encode("utf-8"),
            capture_output=True,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertIn(b"valid runtime performance report", completed.stdout)

        invalid = report(generatedAt="2026-09-23T12:00:00+03:00")
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "-"],
            input=json.dumps(invalid).encode("utf-8"),
            capture_output=True,
        )
        self.assertNotEqual(completed.returncode, 0)

    def test_cli_release_mode_rejects_partial_report(self) -> None:
        partial = report(status="partial", sampleCount=2)
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--require-verified", "-"],
            input=json.dumps(partial).encode("utf-8"),
            capture_output=True,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(b"release mode", completed.stderr)


if __name__ == "__main__":
    unittest.main()
