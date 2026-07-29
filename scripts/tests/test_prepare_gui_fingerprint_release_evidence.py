import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-gui-fingerprint-release-evidence.py"
SPEC = importlib.util.spec_from_file_location(
    "prepare_gui_fingerprint_release_evidence",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

VERIFIER_TESTS = Path(__file__).resolve().parent / "test_verify_gui_fingerprint_report.py"
VERIFIER_SPEC = importlib.util.spec_from_file_location(
    "test_verify_gui_fingerprint_report",
    VERIFIER_TESTS,
)
assert VERIFIER_SPEC and VERIFIER_SPEC.loader
VERIFIER_FIXTURES = importlib.util.module_from_spec(VERIFIER_SPEC)
sys.modules[VERIFIER_SPEC.name] = VERIFIER_FIXTURES
VERIFIER_SPEC.loader.exec_module(VERIFIER_FIXTURES)


class PrepareGuiFingerprintReleaseEvidenceTests(unittest.TestCase):
    def test_reports_unqualified_latest_report_without_collecting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "audit-bad.json"
            report = VERIFIER_FIXTURES.production_report()
            report["executionMode"] = "headless-single-process-diagnostic"
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            status = MODULE.prepare(
                source=None,
                audits_dir=root,
                output=output,
                collect=False,
                runtime_lock=runtime_lock,
            )

            self.assertFalse(status["qualified"])
            self.assertFalse(output.exists())
            self.assertIn("diagnostic mode", " ".join(status["issues"]))

    def test_collects_qualified_report_when_requested(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated_app = VERIFIER_FIXTURES.write_integrated_app_fixture(
                root
            )
            expected = (
                MODULE.COLLECTOR.GUI_VERIFIER
                .expected_runtime_evidence_from_app(integrated_app)
            )
            source = root / "audit-good.json"
            report = VERIFIER_FIXTURES.production_report()
            report["runtimeExecutableSHA256"] = expected[
                "runtimeExecutableSHA256"
            ]
            report["runtimeFrameworkSHA256"] = expected[
                "runtimeFrameworkSHA256"
            ]
            source.write_text(
                json.dumps(report),
                encoding="utf-8",
            )
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            status = MODULE.prepare(
                source=source,
                audits_dir=root,
                output=output,
                collect=True,
                runtime_lock=runtime_lock,
                integrated_app=integrated_app,
            )

            self.assertTrue(status["qualified"])
            self.assertEqual(Path(status["collectedTo"]), output)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_text_handoff_includes_next_step_for_qualified_uncollected_report(self) -> None:
        status = {
            "source": "/tmp/audit-good.json",
            "runtimeName": "NeAntik Browser",
            "runtimeVersion": "150.0.7871.186",
            "executionMode": "browser",
            "changedCriticalKeys": ["canvas", "webgl_pixels"],
            "runtimeLock": "runtime/fingerprint-chromium.lock.json",
            "runtimeVerificationCreatedAt": "2026-07-25T08:29:00Z",
            "createdAt": "2026-07-25T08:29:41Z",
            "qualified": True,
            "issues": [],
            "productionQualified": False,
            "productionIssues": ["strict pending"],
            "releaseQualification": "public-alpha",
            "releaseQualified": True,
        }

        text = MODULE.format_text(
            status,
            output=Path("dist/fingerprint-audit.json"),
            collect=False,
        )

        self.assertIn("qualified public-alpha GUI", text)
        self.assertIn("production hardening remains incomplete", text)
        self.assertIn("Runtime lock", text)
        self.assertIn("Runtime verification created", text)
        self.assertIn("Report created", text)
        self.assertIn("--collect", text)

    def test_json_error_shape_is_small_and_non_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)
            with self.assertRaises(MODULE.COLLECTOR.EvidenceCollectionError):
                MODULE.analyze(source=None, audits_dir=root, runtime_lock=runtime_lock)


if __name__ == "__main__":
    unittest.main()
