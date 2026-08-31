from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STARTUP = load_script("measure-manager-startup.py")
RESOURCES = load_script("measure-manager-resources.py")


class ManagerMetricTests(unittest.TestCase):
    def test_startup_summary_separates_first_and_warm_runs(self) -> None:
        report = STARTUP.summarize([1200.04, 800.0, 1000.0])
        self.assertEqual(report["coldMilliseconds"], 1200.0)
        self.assertEqual(report["warmMedianMilliseconds"], 900.0)
        self.assertEqual(report["sampleCount"], 3)

    def test_startup_rejects_non_development_bundle(self) -> None:
        with tempfile.TemporaryDirectory(suffix=".app") as temporary:
            with self.assertRaises(STARTUP.StartupMeasurementError):
                STARTUP.validate_app(Path(temporary).resolve())

    def test_startup_measurement_service_is_bounded_and_isolated(self) -> None:
        service = STARTUP.measurement_service("neantik-startup-Ab_C", 2)
        self.assertEqual(
            service,
            "app.neantik.dev.startup.neantik-startup-Ab-C.2",
        )
        self.assertNotEqual(service, "app.neantik.dev.proxy")

    def test_resource_parser_and_summary_are_deterministic(self) -> None:
        self.assertEqual(RESOURCES.parse_ps_sample(" 1.5 102400\n"), (1.5, 102400))
        report = RESOURCES.summarize([(1.0, 102400), (3.0, 122880)])
        self.assertEqual(report["averageCPUPercent"], 2.0)
        self.assertEqual(report["maximumRSSMiB"], 120.0)

    def test_resource_parser_rejects_unbounded_output(self) -> None:
        with self.assertRaises(RESOURCES.ResourceMeasurementError):
            RESOURCES.parse_ps_sample("1.0 100 200")


if __name__ == "__main__":
    unittest.main()
