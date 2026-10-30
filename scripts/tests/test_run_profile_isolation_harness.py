import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "run-profile-isolation-harness.py"
VERIFY = ROOT / "verify-profile-isolation-report.py"
SPEC = importlib.util.spec_from_file_location("profile_harness", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ProfileIsolationHarnessTests(unittest.TestCase):
    def test_real_process_harness_emits_verified_minimized_report(self):
        report = MODULE.run(3)
        self.assertEqual(report["status"], "partial")
        self.assertEqual(report["profileCount"], 3)
        self.assertEqual(report["distinctBrowserDataDirectories"], 3)
        self.assertEqual(report["distinctIdentitySeeds"], 3)
        self.assertEqual(report["sharedCookieStores"], 0)
        self.assertEqual(report["sharedLockFiles"], 0)
        self.assertTrue(report["concurrentLaunchBlocked"])
        self.assertEqual(report["recoveryState"], "clean")
        self.assertEqual(report["storageIsolation"], "verified")

    def test_synthetic_storage_leak_fails_closed(self):
        report = MODULE.run(2, inject_storage_leak=True)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["storageIsolation"], "failed")

    def test_cli_report_is_accepted_by_contract_verifier(self):
        produced = subprocess.run(
            [sys.executable, str(SCRIPT), "--count", "2", "--json"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(produced.returncode, 0, produced.stderr)
        report = json.loads(produced.stdout)
        self.assertEqual(report["profileCount"], 2)
        self.assertEqual(report["storageIsolation"], "verified")
        verified = subprocess.run(
            [sys.executable, str(VERIFY), "-"],
            input=produced.stdout,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_count_is_bounded(self):
        with self.assertRaises(SystemExit):
            MODULE.main(["--count", "0"])


if __name__ == "__main__":
    unittest.main()
