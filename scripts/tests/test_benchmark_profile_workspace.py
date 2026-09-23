import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "benchmark-profile-workspace.py"
SPEC = importlib.util.spec_from_file_location("benchmark_profile_workspace", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class BenchmarkProfileWorkspaceTests(unittest.TestCase):
    def test_synthetic_workspace_is_deterministic_and_projects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "workspace"
            root.mkdir()
            byte_count = MODULE.create_synthetic_workspace(root, 2)

            self.assertEqual(byte_count, sum(
                path.stat().st_size for path in root.glob("*/metadata.json")
            ))
            self.assertEqual(
                [item["id"] for item in MODULE.warm_projection(root)],
                ["synthetic-0001", "synthetic-0002"],
            )

    def test_cli_emits_only_contract_fields(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--counts", "1", "50", "--iterations", "2"],
            check=True,
            capture_output=True,
            text=True,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(
            set(result),
            {
                "counts",
                "durations_ms",
                "bytes",
                "platform",
                "arch",
                "status",
                "budget_status",
                "budget_results",
                "runtime_status",
            },
        )
        self.assertEqual(result["counts"], [1, 50])
        self.assertEqual(result["status"], "synthetic-manager-level")
        self.assertEqual(result["budget_status"], "passed")
        self.assertEqual(result["runtime_status"], "unverified")
        self.assertEqual(set(result["bytes"]), {"1", "50"})
        for metric in ("cold_setup", "warm_projection"):
            for percentile_name in ("p50", "p95"):
                self.assertEqual(
                    set(result["durations_ms"][metric][percentile_name]),
                    {"1", "50"},
                )
                for count in ("1", "50"):
                    self.assertEqual(
                        result["budget_results"][metric][percentile_name][count][
                            "status"
                        ],
                        "pass",
                    )

    def test_budget_evaluation_reports_a_regression(self) -> None:
        durations = {
            "cold_setup": {
                "p50": {"1": 5.001},
                "p95": {"1": 10.001},
            },
            "warm_projection": {
                "p50": {"1": 2.001},
                "p95": {"1": 5.001},
            },
        }

        results, status = MODULE.evaluate_budgets([1], durations)

        self.assertEqual(status, "failed")
        self.assertEqual(results["cold_setup"]["p95"]["1"]["status"], "fail")

    def test_cli_rejects_invalid_iterations(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--iterations", "0"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("between 1 and", completed.stderr)

    def test_cli_rejects_unsupported_count(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--counts", "2"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("invalid choice", completed.stderr)


if __name__ == "__main__":
    unittest.main()
