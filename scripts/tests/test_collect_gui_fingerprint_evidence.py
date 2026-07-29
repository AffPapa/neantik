import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


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
            report = VERIFIER_FIXTURES.production_report()
            report["firstInitial"]["profileName"] = "Личный профиль"
            report["second"]["profileName"] = "Рабочий профиль"
            original_first_id = report["firstInitial"]["profileID"]
            original_second_id = report["second"]["profileID"]
            original_first_identity = report["firstInitial"][
                "identityCode"
            ]
            original_second_identity = report["second"]["identityCode"]
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            summary_output = (
                root / "dist" / "fingerprint-audit-summary.json"
            )
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            result = MODULE.collect_evidence(
                source=source,
                audits_dir=root,
                output=output,
                runtime_lock=runtime_lock,
                summary_output=summary_output,
            )

            mode = os.stat(output).st_mode & 0o777
            self.assertEqual(Path(result["output"]), output)
            self.assertTrue(result["summary"]["qualified"])
            self.assertEqual(mode, 0o600)
            collected = json.loads(output.read_text(encoding="utf-8"))
            self.assertNotEqual(collected, report)
            self.assertEqual(
                collected["firstInitial"]["profileName"],
                "Профиль A",
            )
            self.assertNotIn("Личный профиль", output.read_text(encoding="utf-8"))
            self.assertNotIn("Рабочий профиль", output.read_text(encoding="utf-8"))
            self.assertEqual(
                collected["firstInitial"]["profileID"],
                collected["firstRepeat"]["profileID"],
            )
            self.assertNotEqual(
                collected["firstInitial"]["profileID"],
                original_first_id,
            )
            collected_text = output.read_text(encoding="utf-8")
            for private_value in (
                original_first_id,
                original_second_id,
                original_first_identity,
                original_second_identity,
            ):
                self.assertNotIn(private_value, collected_text)
            self.assertEqual(
                MODULE.GUI_VERIFIER.tuple_for_identity(
                    collected["firstInitial"]["identityCode"]
                ),
                MODULE.GUI_VERIFIER.tuple_for_identity(
                    original_first_identity
                ),
            )
            self.assertEqual(
                MODULE.GUI_VERIFIER.tuple_for_identity(
                    collected["second"]["identityCode"]
                ),
                MODULE.GUI_VERIFIER.tuple_for_identity(
                    original_second_identity
                ),
            )
            public_summary = json.loads(
                summary_output.read_text(encoding="utf-8")
            )
            self.assertEqual(
                public_summary["kind"],
                "neantik-gui-fingerprint-attestation",
            )
            summary_text = summary_output.read_text(encoding="utf-8")
            for forbidden in (
                "firstInitial",
                "second",
                "firstRepeat",
                "webrtcDirectControl",
                "profileID",
                "profileName",
                "identityCode",
                '"values"',
                original_first_id,
                original_first_identity,
                "Личный профиль",
            ):
                self.assertNotIn(forbidden, summary_text)
            self.assertEqual(result["summaryOutput"], str(summary_output))
            self.assertEqual(
                public_summary["privateEvidenceSHA256"],
                result["privateEvidenceSHA256"],
            )
            self.assertEqual(
                MODULE.verify_attestation_binding(
                    private_evidence=output,
                    attestation=summary_output,
                ),
                result["privateEvidenceSHA256"],
            )

            output.write_bytes(output.read_bytes() + b" ")
            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "does not match",
            ):
                MODULE.verify_attestation_binding(
                    private_evidence=output,
                    attestation=summary_output,
                )

    def test_private_writer_does_not_follow_predictable_temp_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            victim = root / "victim.txt"
            victim.write_text("must survive", encoding="utf-8")
            output = root / "fingerprint-audit.json"
            predictable = root / ".fingerprint-audit.json.tmp"
            predictable.symlink_to(victim)

            MODULE.write_private_json(output, {"schemaVersion": 5})

            self.assertEqual(victim.read_text(encoding="utf-8"), "must survive")
            self.assertTrue(predictable.is_symlink())
            self.assertFalse(output.is_symlink())
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                {"schemaVersion": 5},
            )

    def test_newest_mtime_report_is_rejected_when_created_before_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audits = root / "audits"
            audits.mkdir()
            fresh = audits / "audit-fresh.json"
            stale = audits / "audit-stale-newest-mtime.json"
            fresh.write_text(
                json.dumps(VERIFIER_FIXTURES.production_report()),
                encoding="utf-8",
            )
            stale_report = VERIFIER_FIXTURES.production_report()
            stale_report["createdAt"] = "2026-07-25T08:29:30Z"
            stale.write_text(json.dumps(stale_report), encoding="utf-8")
            now = time.time()
            os.utime(fresh, (now - 5, now - 5))
            os.utime(stale, (now, now))
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "predates the current GUI collection attempt",
            ):
                MODULE.collect_evidence(
                    source=None,
                    audits_dir=audits,
                    output=output,
                    runtime_lock=runtime_lock,
                    not_before=datetime(
                        2026,
                        7,
                        25,
                        8,
                        29,
                        40,
                        tzinfo=timezone.utc,
                    ),
                )

            self.assertFalse(output.exists())

    def test_accepts_report_created_at_not_before_attempt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "audit-fresh.json"
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
                not_before=MODULE.parse_not_before(
                    "2026-07-25T08:29:40Z"
                ),
            )

            self.assertTrue(result["summary"]["qualified"])

    def test_rejects_report_created_in_same_second_as_attempt_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "audit-same-second.json"
            source.write_text(
                json.dumps(VERIFIER_FIXTURES.production_report()),
                encoding="utf-8",
            )
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "predates the current GUI collection attempt",
            ):
                MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=output,
                    runtime_lock=runtime_lock,
                    not_before=MODULE.parse_not_before(
                        "2026-07-25T08:29:41Z"
                    ),
                )

    def test_rejects_report_timestamp_far_in_future(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = VERIFIER_FIXTURES.production_report()
            report["createdAt"] = (
                datetime.now(timezone.utc) + timedelta(minutes=10)
            ).isoformat().replace("+00:00", "Z")
            source = root / "audit-future.json"
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "implausibly far in the future",
            ):
                MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=output,
                    runtime_lock=runtime_lock,
                )

    def test_attempt_state_quarantines_stale_pair_and_rejects_old_report_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audits = root / "audits"
            audits.mkdir()
            report = VERIFIER_FIXTURES.production_report()
            source = audits / "audit-existing.json"
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            summary = root / "dist" / "fingerprint-audit-summary.json"
            output.parent.mkdir()
            output.write_text("old private", encoding="utf-8")
            summary.write_text("old summary", encoding="utf-8")
            state = root / "attempt-state"

            baseline_path = MODULE.prepare_attempt_state(
                audits_dir=audits,
                output=output,
                summary_output=summary,
                state_dir=state,
            )

            self.assertFalse(output.exists())
            self.assertFalse(summary.exists())
            self.assertEqual(
                (state / "previous-fingerprint-audit.json").read_text(
                    encoding="utf-8"
                ),
                "old private",
            )
            self.assertEqual(
                (state / "previous-fingerprint-audit-summary.json").read_text(
                    encoding="utf-8"
                ),
                "old summary",
            )
            baseline = MODULE.load_report_id_baseline(baseline_path)
            self.assertIn(report["id"], baseline)
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "existed before the current GUI attempt",
            ):
                MODULE.collect_evidence(
                    source=source,
                    audits_dir=audits,
                    output=output,
                    runtime_lock=runtime_lock,
                    baseline_report_ids=baseline,
                )

    def test_failed_summary_write_cannot_leave_stale_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "audit-fresh.json"
            source.write_text(
                json.dumps(VERIFIER_FIXTURES.production_report()),
                encoding="utf-8",
            )
            output = root / "dist" / "fingerprint-audit.json"
            summary = root / "dist" / "fingerprint-audit-summary.json"
            summary.parent.mkdir(parents=True)
            summary.write_text(
                json.dumps(
                    {
                        "privateEvidenceSHA256": "0" * 64,
                        "qualified": True,
                    }
                ),
                encoding="utf-8",
            )
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            with mock.patch.object(
                MODULE,
                "write_private_json",
                side_effect=OSError("simulated summary write failure"),
            ):
                with self.assertRaisesRegex(
                    OSError,
                    "simulated summary write failure",
                ):
                    MODULE.collect_evidence(
                        source=source,
                        audits_dir=root,
                        output=output,
                        runtime_lock=runtime_lock,
                        summary_output=summary,
                    )

            self.assertTrue(output.is_file())
            self.assertFalse(summary.exists())

    def test_rejects_sensitive_extra_fields_without_writing_output(self) -> None:
        mutations = (
            ("top", "cookies"),
            ("capture", "visitedURL"),
            ("values", "proxyPassword"),
        )
        for location, key in mutations:
            with self.subTest(location=location):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    report = VERIFIER_FIXTURES.production_report()
                    if location == "top":
                        report[key] = "secret"
                    elif location == "capture":
                        report["firstInitial"][key] = "secret"
                    else:
                        report["firstInitial"]["values"][key] = "secret"
                    source = root / "audit-sensitive.json"
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
