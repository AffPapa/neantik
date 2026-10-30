import importlib.util
import json
import subprocess
import sys
import unittest
from unittest import mock
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
    def test_loopback_transport_never_reports_browser_route_evidence(self):
        report = MODULE.run()
        self.assertEqual(report["status"], "unverified")
        self.assertFalse(report["effectiveHTTPRouteObserved"])
        self.assertEqual(report["routeMode"], "unknown")
        self.assertEqual(report["negotiatedProtocol"], "unknown")
        self.assertFalse(report["tlsObserved"])
        self.assertEqual(report["dnsPath"], "not_observed")

    def test_successful_real_http_request_cannot_upgrade_browser_evidence(self):
        # Wrap the real opener: the success control must reach the owned server.
        original = MODULE.urllib.request.build_opener
        responses = []
        class ObservedOpener:
            def __init__(self, opener): self.opener = opener
            def open(self, *args, **kwargs):
                response = self.opener.open(*args, **kwargs)
                responses.append(response.status)
                return response
        with mock.patch.object(MODULE.urllib.request, 'build_opener', side_effect=lambda *args: ObservedOpener(original(*args))):
            report = MODULE.run()
        if not responses: self.skipTest('Localhost transport unavailable; successful request control not observed')
        self.assertEqual(responses, [200])
        self.assertEqual(report['status'], 'unverified')
        self.assertFalse(report['effectiveHTTPRouteObserved'])
        self.assertNotIn('runtimeHash', report)

    def test_cli_report_is_accepted_by_contract_verifier(self):
        produced = subprocess.run(
            [sys.executable, str(SCRIPT), "--json"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(produced.returncode, 0, produced.stderr)
        report = json.loads(produced.stdout)
        self.assertEqual(report["status"], "unverified")
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
