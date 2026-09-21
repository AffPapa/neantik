import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "run-network-reality-harness.py"
VERIFY = ROOT / "verify-network-reality-report.py"
SPEC = importlib.util.spec_from_file_location("network_harness", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class NetworkRealityHarnessTests(unittest.TestCase):
    def test_loopback_producer_reports_only_partial_evidence(self):
        report = MODULE.run()
        self.assertIn(report["status"], {"partial", "unverified"})
        if report["status"] == "partial":
            self.assertTrue(report["effectiveHTTPRouteObserved"])
            self.assertEqual(report["routeMode"], "direct")
            self.assertEqual(report["negotiatedProtocol"], "http1")
            self.assertFalse(report["tlsObserved"])
            self.assertEqual(report["dnsPath"], "not_observed")
        else:
            self.assertEqual(report["dnsPath"], "not_observed")

    def test_cli_report_is_accepted_by_contract_verifier(self):
        produced = subprocess.run(
            [sys.executable, str(SCRIPT), "--json"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(produced.returncode, 0, produced.stderr)
        report = json.loads(produced.stdout)
        self.assertIn(report["status"], {"partial", "unverified"})
        verified = subprocess.run(
            [sys.executable, str(VERIFY), "-"],
            input=produced.stdout,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)


if __name__ == "__main__":
    unittest.main()
