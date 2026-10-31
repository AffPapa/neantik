import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "measure-runtime-performance.py"
SPEC = importlib.util.spec_from_file_location(
    "measure_runtime_performance",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class MeasureRuntimePerformanceTests(unittest.TestCase):
    def test_cpu_time_parser_accepts_mac_formats(self) -> None:
        self.assertEqual(MODULE.parse_cpu_time("00:01.50"), 1.5)
        self.assertEqual(MODULE.parse_cpu_time("01:02:03.00"), 3723.0)
        self.assertEqual(MODULE.parse_cpu_time("invalid"), None)

    def test_percentiles_and_report_are_aggregate_only(self) -> None:
        self.assertEqual(MODULE.percentile([1.0, 2.0, 3.0], 0.95), 3.0)
        result = MODULE.build_report(
            "153.0.8010.52",
            "a" * 64,
            [100.0, 200.0, 300.0],
            [50.0, 60.0, 70.0],
            [1.0, 2.0],
            [100.0, 110.0],
            2,
        )
        self.assertEqual(result["status"], "partial")
        self.assertEqual(
            set(result),
            {
                "schemaVersion",
                "status",
                "runtimeVersion",
                "runtimeHash",
                "generatedAt",
                "sampleCount",
                "coldStartMs",
                "warmStartMs",
                "idleCpuPercent",
                "idleMemoryMiB",
            },
        )

    def test_empty_measurements_remain_null(self) -> None:
        result = MODULE.build_report(None, "b" * 64, [], [], [], [], 0)
        self.assertEqual(result["runtimeVersion"], None)
        self.assertEqual(result["sampleCount"], 0)
        self.assertEqual(result["coldStartMs"], {"p50": None, "p95": None})

    def test_runtime_must_be_owned_regular_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "runtime"
            path.write_bytes(b"runtime")
            path.chmod(stat.S_IRUSR | stat.S_IWUSR)
            with self.assertRaises(ValueError):
                MODULE.exact_executable(str(path))

    def test_argument_bounds_are_fail_closed(self) -> None:
        with self.assertRaises(SystemExit):
            MODULE.parse_args(["--runtime", "/tmp/runtime", "--runs", "0"])
        with self.assertRaises(SystemExit):
            MODULE.parse_args(
                ["--runtime", "/tmp/runtime", "--idle-window", "11"]
            )


if __name__ == "__main__":
    unittest.main()
