import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-profile-isolation-report.py"
SPEC = importlib.util.spec_from_file_location("verify_profile_isolation_report", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def valid_report(**overrides):
    report = {
        "status": "verified",
        "profileCount": 3,
        "distinctBrowserDataDirectories": 3,
        "distinctIdentitySeeds": 3,
        "sharedCookieStores": 0,
        "sharedLockFiles": 0,
        "concurrentLaunchBlocked": True,
        "recoveryState": "clean",
        "generatedAt": "2026-09-19T12:34:56Z",
        "runtimeHash": "a" * 64,
    }
    report.update(overrides)
    return report


class VerifyProfileIsolationReportTests(unittest.TestCase):
    def test_accepts_minimized_verified_report(self):
        report = valid_report()
        self.assertEqual(MODULE.validate_report(report), report)

    def test_accepts_non_verified_states_without_inventing_proof(self):
        cases = [
            {"status": "partial", "distinctIdentitySeeds": 2},
            {"status": "unverified", "recoveryState": "unknown"},
            {"status": "blocked", "recoveryState": "required"},
            {"status": "failed", "sharedCookieStores": 1},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                MODULE.validate_report(valid_report(**overrides))

    def test_runtime_hash_is_optional_but_strict(self):
        report = valid_report()
        del report["runtimeHash"]
        self.assertEqual(MODULE.validate_report(report), report)
        for digest in ("A" * 64, "a" * 63, "not-a-digest"):
            with self.subTest(digest=digest):
                with self.assertRaises(MODULE.ProfileIsolationReportError):
                    MODULE.validate_report(valid_report(runtimeHash=digest))

    def test_rejects_arbitrary_sensitive_or_path_fields(self):
        for key in (
            "profilePath",
            "profileName",
            "uuid",
            "cookies",
            "identitySeeds",
            "credentials",
            "notes",
            "observedIP",
        ):
            with self.subTest(key=key):
                report = valid_report()
                report[key] = "/private/secret"
                with self.assertRaisesRegex(
                    MODULE.ProfileIsolationReportError, "unsupported fields"
                ):
                    MODULE.validate_report(report)

    def test_rejects_missing_and_extra_fields(self):
        report = valid_report()
        del report["sharedLockFiles"]
        with self.assertRaisesRegex(
            MODULE.ProfileIsolationReportError, "missing fields"
        ):
            MODULE.validate_report(report)
        report = valid_report(arbitrary={"nested": "data"})
        with self.assertRaisesRegex(
            MODULE.ProfileIsolationReportError, "unsupported fields"
        ):
            MODULE.validate_report(report)

    def test_rejects_invalid_types_enums_and_unbounded_counts(self):
        invalid = [
            {"status": "maybe"},
            {"profileCount": 0},
            {"profileCount": True},
            {"distinctIdentitySeeds": -1},
            {"sharedLockFiles": 100001},
            {"concurrentLaunchBlocked": "true"},
            {"recoveryState": "recovered-with-profile-names"},
            {"generatedAt": "2026-09-19T12:34:56+07:00"},
        ]
        for overrides in invalid:
            with self.subTest(overrides=overrides):
                with self.assertRaises(MODULE.ProfileIsolationReportError):
                    MODULE.validate_report(valid_report(**overrides))

    def test_rejects_count_inconsistency(self):
        cases = [
            {"distinctBrowserDataDirectories": 4},
            {"distinctIdentitySeeds": 4},
            {"sharedCookieStores": 4},
            {"sharedLockFiles": 4},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                with self.assertRaises(MODULE.ProfileIsolationReportError):
                    MODULE.validate_report(valid_report(**overrides))

    def test_verified_requires_all_isolation_gates(self):
        cases = [
            {"distinctBrowserDataDirectories": 2},
            {"distinctIdentitySeeds": 2},
            {"sharedCookieStores": 1},
            {"sharedLockFiles": 1},
            {"concurrentLaunchBlocked": False},
            {"recoveryState": "recovered"},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                with self.assertRaises(MODULE.ProfileIsolationReportError):
                    MODULE.validate_report(valid_report(**overrides))

    def test_rejects_contradictory_failed_and_blocked_states(self):
        with self.assertRaises(MODULE.ProfileIsolationReportError):
            MODULE.validate_report(valid_report(status="failed"))
        with self.assertRaises(MODULE.ProfileIsolationReportError):
            MODULE.validate_report(valid_report(status="blocked", recoveryState="clean"))

    def test_rejects_duplicate_json_keys(self):
        with self.assertRaisesRegex(MODULE.ProfileIsolationReportError, "Duplicate"):
            json.loads(
                '{"status":"verified","status":"partial"}',
                object_pairs_hook=MODULE._reject_duplicate_keys,
            )

    def test_rejects_non_object_nonstandard_json_and_oversized_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, content in (
                ("array.json", "[]"),
                ("nan.json", '{"value": NaN}'),
                ("large.json", "{" + "x" * MODULE.MAX_JSON_BYTES + "}"),
            ):
                path = root / name
                path.write_text(content, encoding="utf-8")
                with self.subTest(name=name):
                    with self.assertRaises(MODULE.ProfileIsolationReportError):
                        MODULE.verify_path(path)

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
            self.assertIn("valid profile isolation report", valid.stdout)
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
