import importlib.util
import base64
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
            "f\"{result['releaseQualification']} GUI fingerprint evidence \"",
            source,
        )
        self.assertIn(
            "choices=(\"public-alpha\", \"production\")",
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
            candidate_manifest = root / "direct-candidate-manifest.json"
            candidate_manifest.write_bytes(b"immutable candidate manifest\n")

            result = MODULE.collect_evidence(
                source=source,
                audits_dir=root,
                output=output,
                runtime_lock=runtime_lock,
                summary_output=summary_output,
                candidate_manifest=candidate_manifest,
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
                public_summary["candidateManifestSHA256"],
                MODULE.hashlib.sha256(
                    candidate_manifest.read_bytes()
                ).hexdigest(),
            )
            self.assertEqual(
                public_summary["releaseChannel"],
                "public-alpha",
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

    def test_direct_candidate_collects_only_authenticated_schema8(self) -> None:
        fixture_path = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "fingerprint-evidence-schema8-swift.json"
        )
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        manifest_raw = base64.b64decode(
            fixture["manifestBase64"],
            validate=True,
        )
        envelope_raw = base64.b64decode(
            fixture["envelopeBase64"],
            validate=True,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "finished-schema8.json"
            manifest = root / "direct-candidate-manifest.json"
            output = root / "dist" / "fingerprint-audit.json"
            summary = root / "dist" / "fingerprint-audit-summary.json"
            source.write_bytes(envelope_raw)
            manifest.write_bytes(manifest_raw)
            expected_runtime = {
                "managerVersion": "0.3.12",
                "managerBuild": "15",
                "runtimeVersion": "150.0.7871.186",
                "runtimeExecutableSHA256": "a" * 64,
                "runtimeFrameworkSHA256": "b" * 64,
            }
            with mock.patch.object(
                MODULE.GUI_VERIFIER,
                "expected_runtime_evidence_from_app",
                return_value=expected_runtime,
            ):
                result = MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=output,
                    runtime_lock=root / "unused-lock.json",
                    integrated_app=root / "NeAntik.app",
                    candidate_manifest=manifest,
                    summary_output=summary,
                    release_channel="public-alpha",
                )

            self.assertEqual(output.read_bytes(), envelope_raw)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            attestation = json.loads(summary.read_text(encoding="utf-8"))
            self.assertEqual(attestation["schemaVersion"], 3)
            self.assertEqual(
                attestation["authenticatedEvidenceID"],
                fixture["expected"]["authenticatedEvidenceID"],
            )
            self.assertEqual(
                attestation["privateEvidenceSHA256"],
                fixture["expected"]["transportSHA256"],
            )
            self.assertEqual(
                result["privateEvidenceSHA256"],
                fixture["expected"]["transportSHA256"],
            )
            for forbidden in (
                "profileName",
                "profileID",
                "identityCode",
                "values",
                "challenge",
                "signatureDER",
            ):
                self.assertNotIn(
                    forbidden,
                    summary.read_text(encoding="utf-8"),
                )

            source.write_text(
                json.dumps(VERIFIER_FIXTURES.production_report()),
                encoding="utf-8",
            )
            with mock.patch.object(
                MODULE.GUI_VERIFIER,
                "expected_runtime_evidence_from_app",
                return_value=expected_runtime,
            ):
                with self.assertRaisesRegex(
                    MODULE.EvidenceCollectionError,
                    "schema-8",
                ):
                    MODULE.collect_evidence(
                        source=source,
                        audits_dir=root,
                        output=root / "dist" / "second.json",
                        runtime_lock=root / "unused-lock.json",
                        integrated_app=root / "NeAntik.app",
                        candidate_manifest=manifest,
                        release_channel="public-alpha",
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

    def test_authenticated_collection_rejects_overlapping_paths_before_write(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "schema8.json"
            source.write_text("{}", encoding="utf-8")
            runtime_lock = root / "runtime-lock.json"

            for output, summary in (
                (root / "same.json", root / "same.json"),
                (source, root / "summary.json"),
                (root / "private.json", source),
            ):
                with self.subTest(output=output, summary=summary):
                    with self.assertRaisesRegex(
                        MODULE.EvidenceCollectionError,
                        "paths must be distinct",
                    ):
                        MODULE.collect_evidence(
                            source=source,
                            audits_dir=root,
                            output=output,
                            runtime_lock=runtime_lock,
                            integrated_app=root / "NeAntik.app",
                            candidate_manifest=root / "manifest.json",
                            summary_output=summary,
                        )

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

    def test_direct_app_without_schema3_manifest_is_rejected(self) -> None:
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

            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "schema-3 manifest",
            ):
                MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=output,
                    runtime_lock=runtime_lock,
                    integrated_app=integrated_app,
                )

    def test_verify_only_authenticated_evidence_writes_nothing(self) -> None:
        fixture_path = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "fingerprint-evidence-schema8-swift.json"
        )
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        manifest_raw = base64.b64decode(
            fixture["manifestBase64"],
            validate=True,
        )
        envelope_raw = base64.b64decode(
            fixture["envelopeBase64"],
            validate=True,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "fingerprint-evidence-schema8.json"
            manifest = root / "direct-candidate-manifest.json"
            output = root / "fingerprint-audit.json"
            summary = root / "fingerprint-audit-summary.json"
            source.write_bytes(envelope_raw)
            manifest.write_bytes(manifest_raw)
            expected_runtime = {
                "managerVersion": "0.3.12",
                "managerBuild": "15",
                "runtimeVersion": "150.0.7871.186",
                "runtimeExecutableSHA256": "a" * 64,
                "runtimeFrameworkSHA256": "b" * 64,
            }
            with mock.patch.object(
                MODULE.GUI_VERIFIER,
                "expected_runtime_evidence_from_app",
                return_value=expected_runtime,
            ):
                result = MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=output,
                    runtime_lock=root / "unused-lock.json",
                    integrated_app=root / "NeAntik.app",
                    candidate_manifest=manifest,
                    summary_output=summary,
                    release_channel="public-alpha",
                    persist_outputs=False,
                )

            self.assertIsNone(result["output"])
            self.assertIsNone(result["summaryOutput"])
            self.assertFalse(output.exists())
            self.assertFalse(summary.exists())

    def test_production_collection_rejects_public_alpha_only_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = VERIFIER_FIXTURES.production_report()
            report["firstInitial"]["values"]["audio_repeat"] = "strict-mismatch"
            report["firstRepeat"]["values"]["audio_repeat"] = "strict-mismatch"
            source = root / "audit-alpha-only.json"
            source.write_text(json.dumps(report), encoding="utf-8")
            output = root / "dist" / "fingerprint-audit.json"
            runtime_lock = VERIFIER_FIXTURES.write_runtime_lock_fixture(root)

            alpha_result = MODULE.collect_evidence(
                source=source,
                audits_dir=root,
                output=output,
                runtime_lock=runtime_lock,
                release_channel="public-alpha",
            )
            self.assertEqual(
                alpha_result["releaseQualification"],
                "public-alpha",
            )
            with self.assertRaisesRegex(
                MODULE.EvidenceCollectionError,
                "not production-qualified",
            ):
                MODULE.collect_evidence(
                    source=source,
                    audits_dir=root,
                    output=root / "dist" / "production.json",
                    runtime_lock=runtime_lock,
                    release_channel="production",
                )

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
