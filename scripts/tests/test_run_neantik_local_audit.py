import importlib.util
import json
import sys
import unittest
from datetime import date, timedelta
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "run-neantik-local-audit.py"
SPEC = importlib.util.spec_from_file_location("local_audit", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class LocalAuditTests(unittest.TestCase):
    def test_expected_baseline_blocker_is_classified_without_raw_output(self):
        check = MODULE.run_check(
            "baseline",
            [sys.executable, "-c", "print('below the security baseline'); raise SystemExit(1)"],
            expected_blocker="below the security baseline",
        )
        self.assertEqual(check, {"id": "baseline", "status": "blocked", "exitCode": 1})

    def test_unexpected_failure_is_not_hidden(self):
        check = MODULE.run_check(
            "unexpected",
            [sys.executable, "-c", "raise SystemExit(3)"],
        )
        self.assertEqual(check["status"], "failed")
        self.assertEqual(check["exitCode"], 3)

    def test_unqualified_cohort_is_a_release_blocker_not_a_crash(self):
        check = MODULE.run_check(
            "baseline",
            [sys.executable, "-c", "print('Public Direct release blocked: coherent Apple device tuples are not verified'); raise SystemExit(1)"],
            expected_blocker="Public Direct release blocked:",
        )
        self.assertEqual(check["status"], "blocked")
        self.assertEqual(check["exitCode"], 1)

    def test_local_audit_keeps_release_blocked(self):
        reviewed = date.fromisoformat(json.loads((SCRIPT.parents[1] / "runtime/security-baseline.json").read_text())["checkedAt"])
        report = MODULE.run_audit(today=reviewed)
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["releaseDecision"], "blocked-until-exact-runtime-and-live-gates")
        self.assertIn(report["overallStatus"], {"partial", "blocked"})
        self.assertEqual(len(report["checks"]), 4)
        self.assertEqual(
            report["checks"][0]["verifierExitCode"],
            0,
        )
        self.assertEqual(report["checks"][1]["verifierExitCode"], 0)

    def test_future_and_stale_review_are_not_accepted_as_expected_blockers(self):
        baseline = json.loads((SCRIPT.parents[1] / "runtime/security-baseline.json").read_text())
        reviewed = date.fromisoformat(baseline["checkedAt"])
        for day in (reviewed - timedelta(days=1), reviewed + timedelta(days=baseline["maximumAgeDays"] + 1)):
            with self.subTest(day=day):
                report = MODULE.run_audit(today=day)
                self.assertEqual(report["checks"][2]["status"], "failed")
                self.assertEqual(report["overallStatus"], "failed")
                self.assertEqual(report["releaseDecision"], "blocked-until-exact-runtime-and-live-gates")


if __name__ == "__main__":
    unittest.main()
