import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-redacted-support-bundle.py"
SPEC = importlib.util.spec_from_file_location("verify_redacted_support_bundle", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def bundle(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "schemaVersion": 1,
        "generatedAt": "2026-09-23T15:00:00Z",
        "manager": {"version": "0.7.4", "build": "74"},
        "runtime": {
            "status": "ready",
            "version": "153.0.8010.52",
            "architecture": "arm64",
            "signature": "valid",
            "executableHash": "a" * 64,
            "frameworkHash": "b" * 64,
        },
        "workspace": {
            "profileCount": 3,
            "activeProfileCount": 2,
            "archivedProfileCount": 1,
            "folderCount": 2,
        },
        "health": {
            "failureCount": 0,
            "attentionCount": 1,
            "recoveryCount": 0,
        },
        "checks": [
            {"id": "profileIsolation", "status": "verified"},
            {"id": "runtimeSecurity", "status": "partial"},
        ],
        "performance": {
            "managerStatus": "verified",
            "runtimeStatus": "unverified",
        },
    }
    value.update(overrides)
    return value


class RedactedSupportBundleTests(unittest.TestCase):
    def test_valid_allowlisted_bundle_is_accepted(self) -> None:
        MODULE.validate_bundle(bundle())

    def test_unknown_fields_and_free_form_notes_are_rejected(self) -> None:
        value = bundle(notes="profile name and proxy.example")
        with self.assertRaises(MODULE.RedactedSupportBundleError):
            MODULE.validate_bundle(value)

        value = bundle()
        value["runtime"] = dict(value["runtime"], path="/Users/alice/BrowserData")
        with self.assertRaises(MODULE.RedactedSupportBundleError):
            MODULE.validate_bundle(value)

    def test_sensitive_values_cannot_fit_allowlisted_runtime_fields(self) -> None:
        value = bundle()
        value["runtime"] = dict(value["runtime"], version="https://proxy.example")
        with self.assertRaises(MODULE.RedactedSupportBundleError):
            MODULE.validate_bundle(value)

        value = bundle()
        value["checks"] = [{"id": "fingerprintAudit", "status": "raw-canvas-value"}]
        with self.assertRaises(MODULE.RedactedSupportBundleError):
            MODULE.validate_bundle(value)

    def test_counts_and_check_ids_are_consistent_and_bounded(self) -> None:
        value = bundle()
        value["workspace"] = dict(value["workspace"], activeProfileCount=4)
        with self.assertRaises(MODULE.RedactedSupportBundleError):
            MODULE.validate_bundle(value)

        value = bundle(checks=[{"id": "profileIsolation", "status": "verified"}] * 2)
        with self.assertRaises(MODULE.RedactedSupportBundleError):
            MODULE.validate_bundle(value)

    def test_duplicate_keys_and_oversized_input_are_rejected(self) -> None:
        payload = json.dumps(bundle())[:-1] + ',"schemaVersion":1}'
        with tempfile.NamedTemporaryFile(mode="wb") as temporary:
            temporary.write(payload.encode("utf-8"))
            temporary.flush()
            with self.assertRaises(MODULE.RedactedSupportBundleError):
                MODULE.load_bundle(temporary.name)

        with tempfile.NamedTemporaryFile(mode="wb") as temporary:
            temporary.write(b"{" + b"x" * (MODULE.MAX_JSON_BYTES + 1))
            temporary.flush()
            with self.assertRaises(MODULE.RedactedSupportBundleError):
                MODULE.load_bundle(temporary.name)

    def test_cli_accepts_stdin_and_reports_contract(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "-"],
            input=json.dumps(bundle()).encode("utf-8"),
            capture_output=True,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertIn(b"valid redacted support bundle", completed.stdout)


if __name__ == "__main__":
    unittest.main()
