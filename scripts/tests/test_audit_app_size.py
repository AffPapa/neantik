import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class AppSizeAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / "NeAntik.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        resources = self.app / "Contents/Resources"
        (resources / "NeAntik Browser.app").mkdir(parents=True)
        (resources / "NeAntikRuntimeCompliance").mkdir()
        (self.app / "Contents/MacOS/NeAntik").write_bytes(b"manager")
        (resources / "NeAntik Browser.app/runtime").write_bytes(b"runtime")
        (resources / "NeAntikRuntimeCompliance/NOTICE").write_bytes(
            b"notice"
        )
        (resources / "Info.txt").write_bytes(b"other")
        self.script = Path(__file__).parents[1] / "audit-app-size.py"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_audit(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.script), str(self.app), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_json_report_has_bounded_components_without_paths(self) -> None:
        result = self.run_audit("--json", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["verdict"], "pass")
        self.assertGreater(report["components"]["runtimeBytes"], 0)
        self.assertNotIn(str(self.root), result.stdout)

    def test_component_budget_fails_independently(self) -> None:
        result = self.run_audit(
            "--json",
            "--check",
            "--manager-max-mib",
            "0",
        )
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["verdict"], "fail")
        self.assertTrue(
            any("manager" in failure for failure in report["failures"])
        )

    def test_rejects_relative_or_incomplete_bundle(self) -> None:
        result = subprocess.run(
            [sys.executable, str(self.script), "NeAntik.app"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("absolute .app", result.stderr)


if __name__ == "__main__":
    unittest.main()
