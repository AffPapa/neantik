import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-network-reality-report.py"
SPEC = importlib.util.spec_from_file_location("verify_network_reality_report", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def valid_report(**overrides):
    report = {
        "status": "verified",
        "routeMode": "proxied",
        "effectiveHTTPRouteObserved": True,
        "dnsPath": "observed",
        "negotiatedProtocol": "http2",
        "tlsObserved": True,
        "webrtcDirectCandidates": 0,
        "bypassDetected": False,
        "generatedAt": "2026-09-19T12:34:56Z",
        "runtimeHash": "a" * 64,
    }
    report.update(overrides)
    return report


class VerifyNetworkRealityReportTests(unittest.TestCase):
    def test_accepts_minimized_verified_report(self):
        self.assertEqual(MODULE.validate_report(valid_report()), valid_report())

    def test_accepts_non_verified_states_without_inventing_evidence(self):
        cases = [
            {"status": "partial", "effectiveHTTPRouteObserved": False},
            {"status": "unverified", "routeMode": "unknown"},
            {"status": "blocked", "dnsPath": "blocked"},
            {"status": "failed", "bypassDetected": True},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                MODULE.validate_report(valid_report(**overrides))

    def test_rejects_extra_sensitive_or_arbitrary_fields(self):
        for key in ("observedIP", "proxyCredentials", "cookies", "headers", "rawICE", "hostname", "notes"):
            with self.subTest(key=key):
                report = valid_report()
                report[key] = "secret"
                with self.assertRaisesRegex(MODULE.NetworkRealityReportError, "unsupported fields"):
                    MODULE.validate_report(report)

    def test_rejects_missing_runtime_hash(self):
        report = valid_report()
        del report["runtimeHash"]
        self.assertEqual(MODULE.validate_report(report), report)

    def test_rejects_invalid_types_and_enums(self):
        invalid = [
            {"routeMode": "configured"},
            {"effectiveHTTPRouteObserved": "true"},
            {"webrtcDirectCandidates": -1},
            {"webrtcDirectCandidates": True},
            {"runtimeHash": "not-a-digest"},
            {"generatedAt": "2026-09-19T12:34:56+07:00"},
        ]
        for overrides in invalid:
            with self.subTest(overrides=overrides):
                with self.assertRaises(MODULE.NetworkRealityReportError):
                    MODULE.validate_report(valid_report(**overrides))

    def test_rejects_contradictory_statuses(self):
        cases = [
            {"status": "verified", "effectiveHTTPRouteObserved": False},
            {"status": "verified", "dnsPath": "not_observed"},
            {"status": "verified", "webrtcDirectCandidates": 1},
            {"status": "failed"},
            {"status": "blocked", "dnsPath": "not_observed"},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                with self.assertRaises(MODULE.NetworkRealityReportError):
                    MODULE.validate_report(valid_report(**overrides))

    def test_rejects_duplicate_json_keys(self):
        with self.assertRaisesRegex(MODULE.NetworkRealityReportError, "Duplicate"):
            json.loads(
                '{"status":"verified","status":"partial"}',
                object_pairs_hook=MODULE._reject_duplicate_keys,
            )

    def test_cli_exit_codes_and_stdin(self):
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report_path.write_text(json.dumps(valid_report()), encoding="utf-8")
            valid = subprocess.run(
                [sys.executable, str(SCRIPT), str(report_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(valid.returncode, 0)
            invalid = subprocess.run(
                [sys.executable, str(SCRIPT), "-"],
                input=json.dumps({"cookies": "secret"}),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(invalid.returncode, 0)


if __name__ == "__main__":
    unittest.main()
