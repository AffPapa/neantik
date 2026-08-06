import hashlib
import importlib.util
import importlib
import json
import os
import fcntl
import stat
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


STATE = load_module(
    "notary_transaction_state_for_inspector_tests",
    SCRIPTS / "notary_transaction_state.py",
)
MODULE = load_module(
    "notary_transaction_inspector_for_tests",
    SCRIPTS / "notary_transaction_inspector.py",
)
NOTARY = importlib.import_module("notarize_direct_transaction")


STAGE_NAMES = tuple(stage for _prefix, stage in STATE.STAGES)
ARCHIVE = "NeAntik-0.3.13-arm64-notarized.zip"
SUBMITTED_BYTES = b"submitted archive fixture"
SUBMITTED_SHA = hashlib.sha256(SUBMITTED_BYTES).hexdigest()
FINAL_BYTES = b"final archive fixture"
FINAL_SHA = hashlib.sha256(FINAL_BYTES).hexdigest()
CHECKSUM_BYTES = f"{FINAL_SHA}  {ARCHIVE}\n".encode()
CHECKSUM_SHA = hashlib.sha256(CHECKSUM_BYTES).hexdigest()
APPLE_ID = "11111111-1111-4111-8111-111111111111"


def write_private(path: Path, payload: object, *, mode: int = 0o400) -> None:
    path.write_bytes(STATE.canonical_json_bytes(payload))
    path.chmod(mode)


def stage_data(stage: str, transaction_id: str) -> dict[str, object]:
    submission_name = f"{transaction_id}-{ARCHIVE}"
    values: dict[str, dict[str, object]] = {
        "transaction-created": {
            "archiveName": ARCHIVE,
            "submissionName": submission_name,
            "releaseChannel": "public-alpha",
            "candidateInputs": {
                "infoPlist": "1" * 64,
                "manifest": "2" * 64,
                "evidence": "3" * 64,
                "attestation": "4" * 64,
                "sourceBinding": "5" * 64,
            },
            "releaseSource": {"schemaVersion": 4},
            "runtimeBuildEvidence": {"schemaVersion": 1},
        },
        "submission-ready": {
            "relativePath": f"submitted/{submission_name}",
            "sha256": SUBMITTED_SHA,
            "size": len(SUBMITTED_BYTES),
        },
        "submit-intent": {
            "submissionName": submission_name,
            "sha256": SUBMITTED_SHA,
            "size": len(SUBMITTED_BYTES),
        },
        "submission-known": {
            "id": APPLE_ID,
            "submissionName": submission_name,
            "sha256": SUBMITTED_SHA,
            "size": len(SUBMITTED_BYTES),
        },
        "accepted": {
            "id": APPLE_ID,
            "submissionName": submission_name,
            "sha256": SUBMITTED_SHA,
            "size": len(SUBMITTED_BYTES),
        },
        "final-verified": {
            "archiveName": ARCHIVE,
            "archiveRelativePath": f"final/{ARCHIVE}",
            "checksumRelativePath": f"final/{ARCHIVE}.sha256",
            "sha256": FINAL_SHA,
            "size": len(FINAL_BYTES),
            "checksumSHA256": CHECKSUM_SHA,
            "checksumSize": len(CHECKSUM_BYTES),
        },
        "sidecar-committed": {
            "name": f"{ARCHIVE}.sha256",
            "sha256": CHECKSUM_SHA,
            "size": len(CHECKSUM_BYTES),
        },
        "zip-committed": {
            "name": ARCHIVE,
            "sha256": FINAL_SHA,
            "size": len(FINAL_BYTES),
        },
        "publication-complete": {
            "archiveName": ARCHIVE,
            "sha256": FINAL_SHA,
            "receipt": f"{ARCHIVE}.{APPLE_ID}.receipt.json",
        },
    }
    return values[stage]


def write_state_chain(
    root: Path,
    transaction_id: str,
    through_stage: str,
) -> None:
    state = root / "state"
    state.mkdir(mode=0o700)
    previous = None
    through_index = STAGE_NAMES.index(through_stage)
    for prefix, stage in STATE.STAGES[: through_index + 1]:
        payload = {
            "schemaVersion": 1,
            "state": stage,
            "transactionId": transaction_id,
            "previousReceiptSHA256": previous,
            "data": stage_data(stage, transaction_id),
        }
        raw = STATE.canonical_json_bytes(payload)
        digest = hashlib.sha256(raw).hexdigest()
        path = state / f"{prefix}-{stage}.{digest}.json"
        path.write_bytes(raw)
        path.chmod(0o400)
        previous = digest


def create_transaction(
    dist: Path,
    *,
    category: str,
    stage: str | None,
    marker: bool = True,
    transaction_id: str | None = None,
) -> Path:
    transaction_id = transaction_id or str(uuid.uuid4())
    if category == "initialization":
        name = f".neantik-notary-init.{transaction_id}"
    elif category == "active":
        name = f".neantik-notary.{transaction_id}"
    else:
        retired = dist / ".notary-retired"
        retired.mkdir(mode=0o700, exist_ok=True)
        name = str(uuid.uuid4())
        dist = retired
    root = dist / name
    root.mkdir(mode=0o700)
    lease = root / ".init-lease"
    lease.touch(mode=0o600)
    lease.chmod(0o600)
    if marker:
        write_private(
            root / ".init-marker.json",
            {
                "schemaVersion": 1,
                "markerType": "neantik-notary-initialization",
                "transactionId": transaction_id,
                "directoryName": (
                    f".neantik-notary-init.{transaction_id}"
                ),
                "activeTarget": f".neantik-notary.{transaction_id}",
                "createdAtUnixNs": 1,
                "externalEffectsAllowed": False,
            },
        )
    if stage is not None:
        for name in MODULE._PRIVATE_DIRECTORIES:
            (root / name).mkdir(mode=0o700)
        write_state_chain(root, transaction_id, stage)
        stage_index = STAGE_NAMES.index(stage)
        if stage_index >= STAGE_NAMES.index("submission-known"):
            submitted = root / "submitted" / (
                f"{transaction_id}-{ARCHIVE}"
            )
            submitted.write_bytes(SUBMITTED_BYTES)
            submitted.chmod(0o400)
        if stage_index >= STAGE_NAMES.index("final-verified"):
            archive = root / "final" / ARCHIVE
            archive.write_bytes(FINAL_BYTES)
            archive.chmod(0o400)
            checksum = root / "final" / f"{ARCHIVE}.sha256"
            checksum.write_bytes(CHECKSUM_BYTES)
            checksum.chmod(0o400)
    return root


def write_reconciliation_marker(root: Path, transaction_id: str) -> None:
    submission_name = f"{transaction_id}-{ARCHIVE}"
    write_private(
        root / "notary-reconciliation.json",
        {
            "archiveName": ARCHIVE,
            "checkedAtUnixNs": 1,
            "historySHA256": "a" * 64,
            "markerType": "neantik-notary-reconciliation",
            "result": "submission-absent",
            "schemaVersion": 1,
            "submissionNameSHA256": hashlib.sha256(
                submission_name.encode("utf-8")
            ).hexdigest(),
            "transactionId": transaction_id,
        },
    )


def tree_snapshot(root: Path) -> tuple[tuple[object, ...], ...]:
    rows = []
    for path in sorted((root, *root.rglob("*"))):
        status = path.lstat()
        content = (
            hashlib.sha256(path.read_bytes()).hexdigest()
            if stat.S_ISREG(status.st_mode)
            else None
        )
        rows.append(
            (
                str(path.relative_to(root)),
                status.st_mode,
                status.st_size,
                status.st_mtime_ns,
                status.st_ctime_ns,
                content,
            )
        )
    return tuple(rows)


class NotaryTransactionInspectorTests(unittest.TestCase):
    def test_state_parser_accepts_legacy_candidate_inputs(self) -> None:
        transaction_id = str(uuid.uuid4())
        created = stage_data("transaction-created", transaction_id)
        inputs = created["candidateInputs"]
        assert isinstance(inputs, dict)
        inputs.pop("sourceBinding")

        context = MODULE._validate_state_data(
            (("transaction-created", created),),
            transaction_id=transaction_id,
        )

        self.assertEqual(context["archive"], ARCHIVE)

    def test_empty_dist_is_release_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])
        self.assertEqual(report["records"], [])

    def test_missing_dist_never_passes_release_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report = MODULE.inspect_dist(Path(temporary) / "missing")
        self.assertTrue(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["reasonCode"],
            "release-dist-missing",
        )

    def test_active_stage_matrix_is_fail_closed_at_ambiguous_boundary(
        self,
    ) -> None:
        expected_ready = {
            "transaction-created": False,
            "submission-ready": False,
            "submit-intent": False,
            "submission-known": True,
            "accepted": True,
            "final-verified": True,
            "sidecar-committed": True,
            "zip-committed": True,
            "publication-complete": True,
        }
        for stage, ready in expected_ready.items():
            with self.subTest(stage=stage):
                with tempfile.TemporaryDirectory() as temporary:
                    dist = Path(temporary) / "dist"
                    dist.mkdir()
                    create_transaction(
                        dist,
                        category="active",
                        stage=stage,
                    )
                    report = MODULE.inspect_dist(
                        dist,
                        expected_archive_name=ARCHIVE,
                    )
                self.assertTrue(report["safe"])
                self.assertEqual(report["releaseReady"], ready)
                self.assertEqual(
                    report["records"][0]["stage"],
                    stage,
                )

    def test_initialization_is_blocking_and_abandoned_is_actionable(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            create_transaction(
                dist,
                category="initialization",
                stage=None,
            )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["status"],
            "initialization-abandoned",
        )
        self.assertTrue(report["records"][0]["operatorAction"])

    def test_safe_retired_history_is_counted_but_not_enumerated(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            create_transaction(
                dist,
                category="retired",
                stage="publication-complete",
            )
            create_transaction(
                dist,
                category="retired",
                stage=None,
                marker=False,
            )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["releaseReady"])
        self.assertEqual(report["summary"]["retiredCount"], 2)
        self.assertEqual(report["records"], [])

    def test_finder_metadata_does_not_block_safe_retired_history(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="retired",
                stage="transaction-created",
            )
            retired = dist / ".notary-retired"
            (retired / ".DS_Store").write_bytes(b"finder metadata")
            (root / ".DS_Store").write_bytes(b"finder metadata")
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])
        self.assertEqual(report["summary"]["retiredCount"], 1)
        self.assertEqual(report["records"], [])

    def test_interrupted_retired_external_effect_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            create_transaction(
                dist,
                category="retired",
                stage="accepted",
            )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["reasonCode"],
            "retired-state-requires-reconciliation",
        )

    def test_reconciled_retired_submit_intent_is_non_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            transaction_id = str(uuid.uuid4())
            root = create_transaction(
                dist,
                category="retired",
                stage="submit-intent",
                transaction_id=transaction_id,
            )
            write_reconciliation_marker(root, transaction_id)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])
        self.assertEqual(report["summary"]["retiredCount"], 1)
        self.assertEqual(report["records"], [])

    def test_malformed_reconciliation_marker_is_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            transaction_id = str(uuid.uuid4())
            root = create_transaction(
                dist,
                category="retired",
                stage="submit-intent",
                transaction_id=transaction_id,
            )
            write_reconciliation_marker(root, transaction_id)
            marker_path = root / "notary-reconciliation.json"
            marker = json.loads(marker_path.read_text())
            marker["submissionNameSHA256"] = "0" * 64
            marker_path.chmod(0o600)
            write_private(marker_path, marker)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertFalse(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["reasonCode"],
            "invalid-reconciliation-schema",
        )

    def test_realistic_independent_retirement_uuid_is_safe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="retired",
                stage="publication-complete",
            )
            marker = json.loads(
                (root / ".init-marker.json").read_text()
            )
            self.assertNotEqual(root.name, marker["transactionId"])
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])

    def test_production_retirement_helper_is_inspector_compatible(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            (
                root,
                root_descriptor,
                lease_descriptor,
                coordinator_descriptor,
                transaction_id,
                status,
            ) = NOTARY.create_initial_transaction_root(dist)
            try:
                retired = NOTARY.retire_exact_transaction(
                    root,
                    descriptor=root_descriptor,
                    expected_device=status.st_dev,
                    expected_inode=status.st_ino,
                )
                self.assertTrue(retired.verified)
                assert retired.destination is not None
                self.assertNotEqual(
                    retired.destination.name,
                    transaction_id,
                )
            finally:
                for descriptor in (
                    lease_descriptor,
                    coordinator_descriptor,
                    root_descriptor,
                ):
                    os.close(descriptor)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])

    def test_active_candidate_mismatch_blocks_new_submission(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            create_transaction(
                dist,
                category="active",
                stage="submission-known",
            )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=(
                    "NeAntik-0.3.14-arm64-notarized.zip"
                ),
            )
        self.assertTrue(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["reasonCode"],
            "active-transaction-not-bound-to-candidate",
        )

    def test_missing_submitted_artifact_is_not_resumable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="submission-known",
            )
            next((root / "submitted").iterdir()).unlink()
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertFalse(report["safe"])
        self.assertFalse(report["releaseReady"])

    def test_recovery_final_paths_and_resume_directory_are_supported(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="final-verified",
            )
            resume_name = "resume-" + "d" * 32
            resume = root / resume_name
            resume.mkdir(mode=0o700)
            for name in ("accepted", "final", "final-check"):
                (resume / name).mkdir(mode=0o700)
            for artifact in tuple((root / "final").iterdir()):
                artifact.rename(resume / "final" / artifact.name)
            receipt = next(
                path
                for path in (root / "state").iterdir()
                if path.name.startswith("40-final-verified.")
            )
            payload = json.loads(receipt.read_text())
            payload["data"]["archiveRelativePath"] = (
                f"{resume_name}/final/{ARCHIVE}"
            )
            payload["data"]["checksumRelativePath"] = (
                f"{resume_name}/final/{ARCHIVE}.sha256"
            )
            raw = STATE.canonical_json_bytes(payload)
            replacement = receipt.with_name(
                "40-final-verified."
                + hashlib.sha256(raw).hexdigest()
                + ".json"
            )
            receipt.unlink()
            replacement.write_bytes(raw)
            replacement.chmod(0o400)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["status"],
            "active-continuation-safe",
        )

    def test_publication_hardlinks_remain_valid_resume_evidence(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="publication-complete",
            )
            os.link(
                root / "final" / ARCHIVE,
                dist / ARCHIVE,
            )
            os.link(
                root / "final" / f"{ARCHIVE}.sha256",
                dist / f"{ARCHIVE}.sha256",
            )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])

    def test_retained_hidden_publication_links_can_be_adopted(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="final-verified",
            )
            final = root / "final"
            for index, name in enumerate(
                (ARCHIVE, f"{ARCHIVE}.sha256"),
                start=1,
            ):
                os.link(
                    final / name,
                    final
                    / (
                        f".{name}.neantik-publish-"
                        f"{index:032x}"
                    ),
                )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])

    def test_partial_and_repeated_resume_fragments_are_nonblocking(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="accepted",
            )
            child_sequences = (
                (),
                ("accepted",),
                ("accepted", "final"),
                ("accepted", "final", "final-check"),
            )
            for index in range(9):
                resume = root / f"resume-{index:032x}"
                resume.mkdir(mode=0o700)
                for child in child_sequences[
                    index % len(child_sequences)
                ]:
                    (resume / child).mkdir(mode=0o700)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])

    def test_live_release_lock_blocks_without_inspector_conflict(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            locks = dist / ".notary-locks"
            locks.mkdir(mode=0o700)
            lock = locks / f".{ARCHIVE}.lock"
            lock.touch(mode=0o600)
            lock.chmod(0o600)
            descriptor = os.open(lock, os.O_RDWR)
            try:
                fcntl.flock(
                    descriptor,
                    fcntl.LOCK_EX | fcntl.LOCK_NB,
                )
                report = MODULE.inspect_dist(
                    dist,
                    expected_archive_name=ARCHIVE,
                )
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)
        self.assertTrue(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["reasonCode"],
            "exclusive-release-lock-held",
        )

    def test_canonical_temporary_files_do_not_poison_history(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="retired",
                stage=None,
                marker=False,
            )
            temporary_marker = root / (
                ".init-marker.json.tmp-" + "a" * 32
            )
            temporary_marker.touch(mode=0o600)
            temporary_marker.chmod(0o600)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])

    def test_canonical_state_temporary_does_not_hide_known_state(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="accepted",
            )
            state_temporary = root / "state" / (
                ".30-accepted."
                + "a" * 64
                + ".json.tmp-"
                + "b" * 32
            )
            state_temporary.touch(mode=0o600)
            state_temporary.chmod(0o600)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])

    def test_multiple_active_transactions_require_reconciliation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            for _index in range(2):
                create_transaction(
                    dist,
                    category="active",
                    stage="submission-known",
                )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["summary"]["releaseBlockingCount"],
            1,
        )

    def test_more_than_legacy_retired_cap_remains_memory_bounded(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            retired = dist / ".notary-retired"
            retired.mkdir(mode=0o700)
            for _index in range(513):
                (retired / str(uuid.uuid4())).mkdir(mode=0o700)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertTrue(report["safe"])
        self.assertTrue(report["releaseReady"])
        self.assertEqual(report["summary"]["retiredCount"], 513)

    def test_deep_json_is_rejected_without_crashing(self) -> None:
        raw = b'{"a":' + b"[" * 70 + b"0" + b"]" * 70 + b"}\n"
        with self.assertRaisesRegex(
            MODULE.NotaryTransactionInspectionError,
            "complexity",
        ):
            MODULE._decode_canonical_json(raw)

    def test_surrogateescaped_filename_is_bounded_unsafe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            try:
                os.mkdir(
                    os.fsencode(dist)
                    + b"/.neantik-notary."
                    + b"\xff",
                    0o700,
                )
            except OSError:
                self.skipTest(
                    "filesystem rejects non-UTF-8 entry names"
                )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertFalse(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(
            report["records"][0]["reasonCode"],
            "invalid-entry-name",
        )

    def test_stage_specific_size_checksum_and_receipt_contracts(
        self,
    ) -> None:
        transaction_id = str(uuid.uuid4())
        valid = [
            (stage, stage_data(stage, transaction_id))
            for stage in STAGE_NAMES
        ]
        cases = []
        oversized = json.loads(json.dumps(valid))
        oversized[1][1]["size"] = 16 * 1024 * 1024 * 1024 + 1
        cases.append(oversized)
        wrong_checksum = json.loads(json.dumps(valid))
        wrong_checksum[5][1]["checksumSHA256"] = "f" * 64
        cases.append(wrong_checksum)
        wrong_receipt = json.loads(json.dumps(valid))
        wrong_receipt[-1][1]["receipt"] = "other.receipt.json"
        cases.append(wrong_receipt)
        for receipts in cases:
            with self.subTest(receipts=receipts[-1][1]):
                with self.assertRaises(
                    MODULE.NotaryTransactionInspectionError
                ):
                    MODULE._validate_state_data(
                        tuple((stage, data) for stage, data in receipts),
                        transaction_id=transaction_id,
                    )

    def test_tampered_cross_stage_data_is_unsafe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="submission-ready",
            )
            state = root / "state"
            target = sorted(state.iterdir())[-1]
            payload = json.loads(target.read_text())
            target.chmod(0o600)
            payload["data"]["relativePath"] = "submitted/other.zip"
            raw = STATE.canonical_json_bytes(payload)
            replacement = state / (
                "10-submission-ready."
                + hashlib.sha256(raw).hexdigest()
                + ".json"
            )
            target.unlink()
            replacement.write_bytes(raw)
            replacement.chmod(0o400)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertFalse(report["safe"])
        self.assertFalse(report["releaseReady"])

    def test_symlinked_marker_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="transaction-created",
            )
            marker = root / ".init-marker.json"
            marker.unlink()
            marker.symlink_to(root / "state")
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertFalse(report["safe"])

    def test_inspection_does_not_change_filesystem(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            create_transaction(
                dist,
                category="active",
                stage="accepted",
            )
            before = tree_snapshot(dist)
            MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
            after = tree_snapshot(dist)
        self.assertEqual(after, before)

    def test_output_omits_sensitive_and_stable_identifiers(self) -> None:
        sentinel = str(uuid.uuid4())
        with tempfile.TemporaryDirectory(
            prefix="neantik-private-user-sentinel-"
        ) as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            create_transaction(
                dist,
                category="active",
                stage="submit-intent",
                transaction_id=sentinel,
            )
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
            rendered = json.dumps(report, sort_keys=True)
            text = MODULE.format_report(report)
        combined = rendered + text
        self.assertNotIn(sentinel, combined)
        self.assertNotIn(ARCHIVE, combined)
        self.assertNotIn(SUBMITTED_SHA, combined)
        self.assertNotIn(temporary, combined)
        self.assertNotIn("sortKey", combined)
        self.assertNotIn("entryRef", combined)

    def test_changed_inventory_never_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            original = MODULE._list_directory
            calls = 0

            def changed(descriptor: int, *, maximum: int):
                nonlocal calls
                calls += 1
                values = original(descriptor, maximum=maximum)
                if calls == 2:
                    return values + ("race-sentinel",)
                return values

            with mock.patch.object(
                MODULE,
                "_list_directory",
                side_effect=changed,
            ):
                report = MODULE.inspect_dist(
                    dist,
                    expected_archive_name=ARCHIVE,
                )
        self.assertFalse(report["safe"])
        self.assertFalse(report["releaseReady"])

    def test_state_inventory_append_during_read_never_passes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            root = create_transaction(
                dist,
                category="active",
                stage="transaction-created",
            )
            original = MODULE._read_regular_file_at
            injected = False

            def append_after_read(
                parent: int,
                name: str,
                **kwargs,
            ):
                nonlocal injected
                raw = original(parent, name, **kwargs)
                if name.startswith("00-") and not injected:
                    injected = True
                    residue = root / "state" / (
                        ".00-transaction-created."
                        + "a" * 64
                        + ".json.tmp-"
                        + "b" * 32
                    )
                    residue.touch(mode=0o600)
                    residue.chmod(0o600)
                return raw

            with mock.patch.object(
                MODULE,
                "_read_regular_file_at",
                side_effect=append_after_read,
            ):
                report = MODULE.inspect_dist(
                    dist,
                    expected_archive_name=ARCHIVE,
                )
        self.assertFalse(report["safe"])
        self.assertFalse(report["releaseReady"])

    def test_actionable_output_is_bounded_without_false_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir()
            retired = dist / ".notary-retired"
            retired.mkdir(mode=0o700)
            for _index in range(70):
                unsafe = retired / str(uuid.uuid4())
                unsafe.mkdir(mode=0o755)
            report = MODULE.inspect_dist(
                dist,
                expected_archive_name=ARCHIVE,
            )
        self.assertFalse(report["safe"])
        self.assertFalse(report["releaseReady"])
        self.assertEqual(len(report["records"]), 64)
        self.assertTrue(report["summary"]["recordsTruncated"])
        self.assertEqual(report["summary"]["unsafeCount"], 70)

    def test_source_has_no_mutation_network_or_process_primitives(
        self,
    ) -> None:
        source = (SCRIPTS / "notary_transaction_inspector.py").read_text()
        forbidden = (
            ".mkdir(",
            ".unlink(",
            ".rmdir(",
            "os.remove(",
            "os.rename(",
            "os.replace(",
            "os.chmod(",
            "os.chown(",
            "os.link(",
            "os.symlink(",
            ".write(",
            "subprocess",
            "socket",
            "urllib",
        )
        for needle in forbidden:
            with self.subTest(needle=needle):
                self.assertNotIn(needle, source)


if __name__ == "__main__":
    unittest.main()
