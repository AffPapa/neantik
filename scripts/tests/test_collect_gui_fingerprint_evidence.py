import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "collect-gui-fingerprint-evidence.py"
SPEC = importlib.util.spec_from_file_location("collect_gui_fingerprint_evidence", SCRIPT)
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


class CollectGuiFingerprintEvidenceTests(unittest.TestCase):
    def test_success_copy_names_the_public_alpha_gate(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            "PASS: public-alpha GUI fingerprint evidence collected.",
            source,
        )
        self.assertNotIn(
            "PASS: production GUI fingerprint evidence collected.",
            source,
        )

    def test_selects_latest_regular_audit_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            audits = Path(temporary)
            older = audits / "audit-1-old.json"
            newer = audits / "audit-2-new.json"
            ignored = audits / "other.json"
            older.write_text("{}", encoding="utf-8")
            ignored.write_text("{}", encoding="utf-8")
            time.sleep(0.001)
            newer.write_text("{}", encoding="utf-8")

            selected = MODULE.select_source_report(source=None, audits_dir=audits)

        self.assertEqual(selected.name, "audit-2-new.json")

    def test_rejects_unqualified_report_without_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "audit-bad.json"
            report = VERIFIER_FIXTURES.production_report()
            report["executionMode"] = "headless-single-process-diagnostic"
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "not public-alpha-qualified",
            ):
                MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=output,
                    runtime_lock=runtime_lock,
                )

            self.assertFalse(output.exists())

    def test_collects_qualified_report_with_private_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "audit-good.json"
            source.write_text(
                json.dumps(VERIFIER_FIXTURES.production_report()),
                encoding="utf-8",
            )
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            result = MODULE.collect_evidence(
                source=source,
                audits_dir=root,
                output=output,
                runtime_lock=runtime_lock,
            )

            mode = os.stat(output).st_mode & 0o777
            self.assertEqual(Path(result["output"]), output)
            self.assertTrue(result["summary"]["qualified"])
            self.assertEqual(mode, 0o600)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), json.loads(source.read_text(encoding="utf-8")))

    def test_binds_collection_to_exact_distributed_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated_app = VERIFIER_FIXTURES.write_integrated_app_fixture(root)
            expected = MODULE.GUI_VERIFIER.expected_runtime_evidence_from_app(
                integrated_app
            )
            report = VERIFIER_FIXTURES.production_report()
            report["runtimeExecutableSHA256"] = expected[
                "runtimeExecutableSHA256"
            ]
            report["runtimeFrameworkSHA256"] = expected[
                "runtimeFrameworkSHA256"
            ]
            source = root / "audit-good.json"
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            result = MODULE.collect_evidence(
                source=source,
                audits_dir=root,
                output=output,
                runtime_lock=runtime_lock,
                integrated_app=integrated_app,
            )

            self.assertTrue(result["summary"]["qualified"])
            self.assertEqual(result["integratedApp"], str(integrated_app))

    def test_rejects_qualified_report_with_runtime_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "audit-stale-runtime.json"
            report = VERIFIER_FIXTURES.production_report()
            report["runtimeExecutableSHA256"] = "c" * 64
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            with self.assertRaisesRegex(MODULE.EvidenceCollectionError, "runtime executable"):
                MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=output,
                    runtime_lock=runtime_lock,
                )

            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
