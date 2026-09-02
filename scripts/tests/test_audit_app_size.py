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
        self.assertEqual(report["schemaVersion"], 2)
        self.assertLessEqual(len(report["topPaths"]), 20)
        self.assertTrue(
            all(
                not Path(item["path"]).is_absolute()
                for item in report["topPaths"]
            )
        )

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

    def test_top_paths_are_deterministic_and_do_not_follow_symlinks(
        self,
    ) -> None:
        resources = self.app / "Contents/Resources"
        (resources / "same-b").write_bytes(b"x" * 64)
        (resources / "same-a").write_bytes(b"x" * 64)
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "huge-secret").write_bytes(b"z" * 4096)
        (resources / "linked-outside").symlink_to(outside)

        first = self.run_audit("--json", "--top-paths", "8")
        second = self.run_audit("--json", "--top-paths", "8")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        paths = [item["path"] for item in json.loads(first.stdout)["topPaths"]]
        self.assertNotIn("Contents/Resources/linked-outside/huge-secret", paths)
        self.assertLess(
            paths.index("Contents/Resources/same-a"),
            paths.index("Contents/Resources/same-b"),
        )

    def test_rejects_external_runtime_symlink(self) -> None:
        runtime = self.app / "Contents/Resources/NeAntik Browser.app"
        runtime.rename(self.root / "original-runtime")
        outside = self.root / "external-runtime"
        outside.mkdir()
        (outside / "Chromium").write_bytes(b"external")
        runtime.symlink_to(outside, target_is_directory=True)

        result = self.run_audit("--json", "--check")

        self.assertEqual(result.returncode, 1)
        self.assertIn("real embedded directory", result.stderr)

    def test_previous_manifest_delta_budget_is_optional_and_enforced(
        self,
    ) -> None:
        baseline_result = self.run_audit("--json", "--top-paths", "3")
        self.assertEqual(baseline_result.returncode, 0, baseline_result.stderr)
        baseline = self.root / "baseline.json"
        baseline.write_text(baseline_result.stdout, encoding="utf-8")
        (self.app / "Contents/MacOS/NeAntik").write_bytes(b"m" * 2048)

        report_result = self.run_audit(
            "--json",
            "--previous-manifest",
            str(baseline),
        )
        self.assertEqual(report_result.returncode, 0, report_result.stderr)
        report = json.loads(report_result.stdout)
        self.assertGreater(report["previousDeltasBytes"]["managerBytes"], 0)

        checked = self.run_audit(
            "--json",
            "--check",
            "--previous-manifest",
            str(baseline),
            "--manager-delta-max-mib",
            "0",
        )
        self.assertEqual(checked.returncode, 1)
        checked_report = json.loads(checked.stdout)
        self.assertTrue(
            any(
                "manager grew" in failure
                for failure in checked_report["failures"]
            )
        )

    def test_delta_budget_requires_previous_manifest(self) -> None:
        result = self.run_audit(
            "--json",
            "--check",
            "--total-delta-max-mib",
            "1",
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("previous-manifest", result.stderr)


if __name__ == "__main__":
    unittest.main()
