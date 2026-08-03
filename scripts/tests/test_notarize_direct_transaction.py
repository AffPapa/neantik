import importlib.util
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "notarize_direct_transaction.py"
SPEC = importlib.util.spec_from_file_location(
    "notarize_direct_transaction",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


SUBMISSION_ID = "11111111-2222-3333-4444-555555555555"


class FakeReleaseRunner:
    def __init__(
        self,
        *,
        mutate_during_submit: bool = False,
        notary_status: str = "Accepted",
        info_identifier: str = SUBMISSION_ID,
        fail_final_verifier: bool = False,
        fail_submit: bool = False,
        history_submission_name: str | None = None,
    ) -> None:
        self.commands: list[list[str]] = []
        self.mutate_during_submit = mutate_during_submit
        self.notary_status = notary_status
        self.info_identifier = info_identifier
        self.fail_final_verifier = fail_final_verifier
        self.fail_submit = fail_submit
        self.history_submission_name = history_submission_name

    def package(self, source: Path, destination: Path) -> None:
        with zipfile.ZipFile(
            destination,
            "w",
            compression=zipfile.ZIP_DEFLATED,
        ) as archive:
            for path in sorted(source.rglob("*")):
                if path.is_file():
                    archive.write(
                        path,
                        path.relative_to(source.parent),
                    )

    def __call__(
        self,
        command: list[str],
        _cwd: Path,
    ) -> MODULE.CommandResult:
        self.commands.append(command)
        if command[:5] == [
            "ditto",
            "--norsrc",
            "-c",
            "-k",
            "--keepParent",
        ]:
            self.package(Path(command[-2]), Path(command[-1]))
            return MODULE.CommandResult(0, "")
        if command[:3] == ["ditto", "-x", "-k"]:
            with zipfile.ZipFile(Path(command[3])) as archive:
                archive.extractall(Path(command[4]))
            return MODULE.CommandResult(0, "")
        if command[:2] == ["codesign", "-dvvv"]:
            return MODULE.CommandResult(
                0,
                "Authority=Developer ID Application: NeAntik Test\n"
                "Timestamp=30 Jul 2026",
            )
        if command[:3] == ["xcrun", "notarytool", "submit"]:
            if self.fail_submit:
                return MODULE.CommandResult(1, "", "network interrupted")
            if self.mutate_during_submit:
                submitted = Path(command[3])
                original = submitted.read_bytes()
                submitted.chmod(0o600)
                submitted.write_bytes(b"swapped")
                submitted.write_bytes(original)
                submitted.chmod(0o400)
            return MODULE.CommandResult(
                0,
                json.dumps(
                    {
                        "id": SUBMISSION_ID,
                        "status": self.notary_status,
                    }
                ),
            )
        if command[:3] == ["xcrun", "notarytool", "wait"]:
            return MODULE.CommandResult(
                0,
                json.dumps(
                    {
                        "id": SUBMISSION_ID,
                        "status": self.notary_status,
                    }
                ),
            )
        if command[:3] == ["xcrun", "notarytool", "info"]:
            return MODULE.CommandResult(
                0,
                json.dumps(
                    {
                        "id": self.info_identifier,
                        "status": "Accepted",
                    }
                ),
            )
        if command[:3] == ["xcrun", "notarytool", "history"]:
            history: dict[str, object] = {"history": []}
            if self.history_submission_name is not None:
                history["history"] = [
                    {
                        "id": SUBMISSION_ID,
                        "name": self.history_submission_name,
                        "status": self.notary_status,
                    }
                ]
            return MODULE.CommandResult(0, json.dumps(history))
        if command[:3] == ["xcrun", "stapler", "staple"]:
            app = Path(command[3])
            signature = app / "Contents" / "_CodeSignature"
            signature.mkdir(parents=True, exist_ok=True)
            (signature / "CodeResources").write_text(
                "stapled-ticket",
                encoding="utf-8",
            )
            return MODULE.CommandResult(0, "")
        if (
            self.fail_final_verifier
            and command
            and command[0].endswith(
                "verify-direct-notarized-archive.py"
            )
        ):
            return MODULE.CommandResult(1, "final gate failed")
        return MODULE.CommandResult(0, "PASS")


class DirectNotaryTransactionTests(unittest.TestCase):
    def source_kwargs(
        self,
        root: Path,
        *,
        commit: str = "a",
    ) -> dict[str, object]:
        snapshot = MODULE.SOURCE.ReleaseSourceSnapshot(
            project_root=root.resolve(),
            payload={
                "schemaVersion": 1,
                "project": "NeAntik",
                "repositoryClaim": "AffPapa/neantik",
                "git": {
                    "objectFormat": "sha1",
                    "commit": commit * 40,
                    "tree": "b" * 40,
                    "worktreeState": "clean",
                },
                "digestAlgorithm": "sha256",
                "closure": [],
                "closureSHA256": "c" * 64,
            },
            files=(),
        )
        return {
            "source_snapshot": snapshot,
            "source_assertion": lambda _snapshot: None,
            "runtime_build_evidence": {
                "schemaVersion": 1,
                "status": "candidate-bound-reviewed-source",
                "binding": "candidate-manifest-critical-files",
                "buildArgumentsSHA256": "1" * 64,
                "runtimeCandidateLockSHA256": "2" * 64,
                "runtimeVerificationSHA256": "3" * 64,
                "sourceContractSHA256": "4" * 64,
                "sourceProvenanceSHA256": "5" * 64,
                "reviewedToolchainLockSHA256": "6" * 64,
            },
        }

    def fixture(self, root: Path) -> dict[str, Path]:
        resources = root / "Resources"
        resources.mkdir()
        with (resources / "Info.plist").open("wb") as file:
            plistlib.dump(
                {"CFBundleShortVersionString": "1.2.3"},
                file,
            )
        dist = root / "dist"
        dist.mkdir(mode=0o700)
        app = dist / "NeAntik.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        (contents / "marker.txt").write_text(
            "candidate-a",
            encoding="utf-8",
        )
        paths = {
            "app": app,
            "manifest": dist / "direct-candidate-manifest.json",
            "evidence": dist / "fingerprint-audit.json",
            "attestation": dist / "fingerprint-audit-summary.json",
        }
        for label, path in paths.items():
            if label != "app":
                path.write_text(
                    json.dumps({"kind": label}) + "\n",
                    encoding="utf-8",
                )
                path.chmod(0o600)
        return paths

    def test_accepted_zip_is_the_only_source_for_stapling_and_publish(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            runner = FakeReleaseRunner()

            def mutate_live_app(
                phase: str,
                _context: dict[str, Path],
            ) -> None:
                if phase == "submission-packaged":
                    (
                        paths["app"] / "Contents" / "marker.txt"
                    ).write_text("candidate-b", encoding="utf-8")

            result = MODULE.run_transaction(
                project_root=root,
                app=paths["app"],
                manifest=paths["manifest"],
                evidence=paths["evidence"],
                attestation=paths["attestation"],
                release_channel="public-alpha",
                notary_profile="test-profile",
                runner=runner,
                phase_hook=mutate_live_app,
                **self.source_kwargs(root),
            )
            archive = Path(result["archive"])
            with zipfile.ZipFile(archive) as final_zip:
                self.assertEqual(
                    final_zip.read(
                        "NeAntik.app/Contents/marker.txt"
                    ).decode("utf-8"),
                    "candidate-a",
                )
                self.assertEqual(
                    final_zip.read(
                        "NeAntik.app/Contents/_CodeSignature/"
                        "CodeResources"
                    ).decode("utf-8"),
                    "stapled-ticket",
                )
            receipt = json.loads(
                Path(result["receipt"]).read_text(encoding="utf-8")
            )
            receipt_path = Path(result["receipt"])
            receipt_text = receipt_path.read_text(encoding="utf-8")
            receipt_mode = stat.S_IMODE(
                receipt_path.parent.stat().st_mode
            )
            archive_mode = stat.S_IMODE(archive.stat().st_mode)
            checksum_mode = stat.S_IMODE(
                Path(result["checksum"]).stat().st_mode
            )
            accepted_receipts = list(
                receipt_path.parent.glob("*.accepted.json")
            )
            accepted_receipt = json.loads(
                accepted_receipts[0].read_text(encoding="utf-8")
            )

        submit = next(
            command
            for command in runner.commands
            if command[:3] == ["xcrun", "notarytool", "submit"]
        )
        self.assertIn(".neantik-notary.", submit[3])
        self.assertIn("/submitted/", submit[3])
        staple = next(
            command
            for command in runner.commands
            if command[:3] == ["xcrun", "stapler", "staple"]
        )
        privacy_check = next(
            command
            for command in runner.commands
            if any(
                argument.endswith(
                    "verify-public-artifact-privacy.py"
                )
                for argument in command
            )
        )
        privacy_script_index = next(
            index
            for index, argument in enumerate(privacy_check)
            if argument.endswith(
                "verify-public-artifact-privacy.py"
            )
        )
        self.assertEqual(
            privacy_check[privacy_script_index + 1],
            privacy_check[
                privacy_check.index("--attestation") + 1
            ],
        )
        self.assertIn("/accepted/NeAntik.app", staple[3])
        self.assertEqual(receipt["appleSubmission"]["status"], "Accepted")
        self.assertEqual(receipt["appleSubmission"]["id"], SUBMISSION_ID)
        self.assertEqual(receipt["finalArchive"]["sha256"], result["sha256"])
        self.assertEqual(receipt["publicationState"], "transaction-verified")
        self.assertEqual(receipt["schemaVersion"], 2)
        self.assertEqual(receipt["receiptType"], "direct-release")
        self.assertEqual(accepted_receipt["schemaVersion"], 2)
        self.assertEqual(
            accepted_receipt["receiptType"],
            "apple-accepted",
        )
        self.assertEqual(
            receipt["candidateInputs"],
            accepted_receipt["candidateInputs"],
        )
        self.assertTrue(
            all(
                set(value) == {"sha256", "size"}
                for value in receipt["candidateInputs"].values()
            )
        )
        self.assertEqual(
            receipt["releaseSource"]["git"]["commit"],
            "a" * 40,
        )
        self.assertEqual(
            receipt["runtimeBuildEvidence"]["binding"],
            "candidate-manifest-critical-files",
        )
        self.assertEqual(
            receipt["runtimeBuildEvidence"]["schemaVersion"],
            1,
        )
        self.assertNotIn("toolchainUsed", receipt["runtimeBuildEvidence"])
        self.assertEqual(receipt_path.parent.name, ".notary-receipts")
        self.assertEqual(receipt_mode, 0o700)
        self.assertEqual(archive_mode, 0o400)
        self.assertEqual(checksum_mode, 0o400)
        self.assertEqual(len(accepted_receipts), 1)
        self.assertNotIn("test-profile", receipt_text)

    @unittest.skipUnless(
        hasattr(__import__("select"), "kqueue"),
        "release observation requires macOS kqueue",
    )
    def test_submit_archive_write_restore_aborts_without_publication(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            runner = FakeReleaseRunner(mutate_during_submit=True)

            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "changed during",
            ):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=runner,
                    **self.source_kwargs(root),
                )

            self.assertFalse(
                (
                    root
                    / "dist"
                    / "NeAntik-1.2.3-arm64-notarized.zip"
                ).exists()
            )

    def test_notary_parser_rejects_text_and_mismatched_info(self) -> None:
        with self.assertRaisesRegex(
            MODULE.DirectNotaryTransactionError,
            "strict JSON",
        ):
            MODULE.parse_notary_result("status: Accepted")
        with self.assertRaisesRegex(
            MODULE.DirectNotaryTransactionError,
            "does not match",
        ):
            MODULE.parse_notary_result(
                json.dumps(
                    {
                        "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                        "status": "Accepted",
                    }
                ),
                expected_identifier=SUBMISSION_ID,
            )

    def test_hosted_url_must_match_pinned_archive(self) -> None:
        MODULE.validate_hosted_download_url(
            (
                "https://github.com/AffPapa/neantik/releases/download/"
                "v1.2.3/NeAntik-1.2.3-arm64-notarized.zip"
            ),
            archive_name="NeAntik-1.2.3-arm64-notarized.zip",
        )
        with self.assertRaisesRegex(
            MODULE.DirectNotaryTransactionError,
            "does not match",
        ):
            MODULE.validate_hosted_download_url(
                "https://example.com/wrong.zip?token=secret",
                archive_name="NeAntik-1.2.3-arm64-notarized.zip",
            )

    def test_success_stderr_is_available_only_when_requested(self) -> None:
        result = MODULE.default_runner(
            [
                sys.executable,
                "-c",
                (
                    "import sys;"
                    "sys.stderr.write('Authority=Developer ID Application:"
                    " Test\\nTimestamp=now\\n')"
                ),
            ],
            Path.cwd(),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.output, "")
        self.assertIn("Authority=Developer ID", result.stderr)
        self.assertEqual(
            MODULE.run_checked(
                ["codesign", "-dvvv", "fixture"],
                cwd=Path.cwd(),
                runner=lambda _command, _cwd: result,
                label="codesign",
                include_stderr=True,
            ),
            result.stderr,
        )

    def test_default_runner_isolates_local_python_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            gate = root / "scripts" / "release_gate.py"
            gate.write_text("print('PASS')\n", encoding="utf-8")
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout="PASS\n",
                stderr="",
            )
            with mock.patch.object(
                MODULE.subprocess,
                "run",
                return_value=completed,
            ) as run:
                result = MODULE.default_runner([str(gate)], root)
            command = run.call_args.args[0]
            environment = run.call_args.kwargs["env"]
            self.assertEqual(
                command[:3],
                [sys.executable, "-I", "-B"],
            )
            self.assertEqual(command[3], str(gate))
            self.assertEqual(
                environment["PYTHONDONTWRITEBYTECODE"],
                "1",
            )
            self.assertEqual(environment["PYTHONNOUSERSITE"], "1")
            self.assertNotIn("PYTHONPATH", environment)
            self.assertEqual(result.output, "PASS")

    def test_rejected_notary_or_final_gate_never_publishes(self) -> None:
        for runner in (
            FakeReleaseRunner(notary_status="Invalid"),
            FakeReleaseRunner(fail_final_verifier=True),
        ):
            with self.subTest(runner=runner):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    paths = self.fixture(root)
                    with self.assertRaises(
                        MODULE.DirectNotaryTransactionError
                    ):
                        MODULE.run_transaction(
                            project_root=root,
                            app=paths["app"],
                            manifest=paths["manifest"],
                            evidence=paths["evidence"],
                            attestation=paths["attestation"],
                            release_channel="public-alpha",
                            notary_profile="test-profile",
                            runner=runner,
                            **self.source_kwargs(root),
                        )
                    self.assertFalse(
                        (
                            root
                            / "dist"
                            / "NeAntik-1.2.3-arm64-notarized.zip"
                        ).exists()
                    )

    def test_input_write_restore_aborts_before_notary_submit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            runner = FakeReleaseRunner()

            def mutate_input(
                phase: str,
                _context: dict[str, Path],
            ) -> None:
                if phase == "inputs-pinned":
                    original = paths["manifest"].read_bytes()
                    paths["manifest"].write_bytes(b"changed")
                    paths["manifest"].write_bytes(original)

            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "input changed",
            ):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=runner,
                    phase_hook=mutate_input,
                    **self.source_kwargs(root),
                )

            self.assertFalse(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "submit"]
                    for command in runner.commands
                )
            )

    def test_unsafe_archive_member_is_rejected_before_extraction(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("../outside", "unsafe")
            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "unexpected entry",
            ):
                MODULE.assert_safe_archive_members(archive)

    def test_archive_symlink_must_remain_inside_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unsafe = root / "unsafe-symlink.zip"
            link = zipfile.ZipInfo(
                "NeAntik.app/Contents/Frameworks/Escape"
            )
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(unsafe, "w") as zip_file:
                zip_file.writestr(link, "../../../outside")
            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "symlink escapes",
            ):
                MODULE.assert_safe_archive_members(unsafe)

            safe = root / "safe-symlink.zip"
            current = zipfile.ZipInfo(
                "NeAntik.app/Contents/Frameworks/Test.framework/"
                "Versions/Current"
            )
            current.create_system = 3
            current.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(safe, "w") as zip_file:
                zip_file.writestr(current, "A")
                zip_file.writestr(
                    "NeAntik.app/Contents/Frameworks/Test.framework/"
                    "Versions/A/Test",
                    "binary",
                )
            MODULE.assert_safe_archive_members(safe)

    def test_cleanup_refuses_replaced_transaction_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / ".neantik-notary.original"
            transaction.mkdir(mode=0o700)
            status = transaction.stat()
            descriptor = os.open(
                transaction,
                os.O_RDONLY | os.O_DIRECTORY,
            )
            moved = root / ".neantik-notary.moved"
            transaction.rename(moved)
            transaction.mkdir(mode=0o700)
            sentinel = transaction / "sentinel"
            sentinel.write_text("keep", encoding="utf-8")

            retirement = MODULE.retire_exact_transaction(
                transaction,
                descriptor=descriptor,
                expected_device=status.st_dev,
                expected_inode=status.st_ino,
            )
            os.close(descriptor)

            self.assertFalse(retirement.moved)
            self.assertEqual(
                sentinel.read_text(encoding="utf-8"),
                "keep",
            )
            self.assertTrue(moved.is_dir())

    def test_retirement_preserves_complete_private_tree_without_deletion(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / ".neantik-notary.original"
            nested = transaction / "nested"
            nested.mkdir(parents=True, mode=0o700)
            sentinel = nested / "sentinel"
            sentinel.write_text("retain", encoding="utf-8")
            status = transaction.stat(follow_symlinks=False)
            descriptor = os.open(
                transaction,
                os.O_RDONLY | os.O_DIRECTORY,
            )
            with (
                mock.patch.object(
                    MODULE.os,
                    "unlink",
                    side_effect=AssertionError("must not unlink"),
                ),
                mock.patch.object(
                    MODULE.os,
                    "rmdir",
                    side_effect=AssertionError("must not rmdir"),
                ),
            ):
                retirement = MODULE.retire_exact_transaction(
                    transaction,
                    descriptor=descriptor,
                    expected_device=status.st_dev,
                    expected_inode=status.st_ino,
                )
            os.close(descriptor)

            self.assertTrue(retirement.moved)
            self.assertTrue(retirement.durable)
            self.assertTrue(retirement.verified)
            retired = retirement.destination
            assert retired is not None
            self.assertFalse(transaction.exists())
            self.assertEqual(
                (retired / "nested" / "sentinel").read_text(
                    encoding="utf-8"
                ),
                "retain",
            )
            self.assertEqual(
                retired.stat(follow_symlinks=False).st_ino,
                status.st_ino,
            )

    def test_initial_transaction_has_durable_marker_and_live_lease(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir(mode=0o700)
            (
                root,
                root_descriptor,
                lease_descriptor,
                coordinator_descriptor,
                transaction_id,
                _root_status,
            ) = MODULE.create_initial_transaction_root(dist)
            try:
                marker_path = root / ".init-marker.json"
                marker = json.loads(
                    marker_path.read_text(encoding="utf-8")
                )
                self.assertEqual(marker["schemaVersion"], 1)
                self.assertEqual(
                    marker["markerType"],
                    "neantik-notary-initialization",
                )
                self.assertEqual(marker["transactionId"], transaction_id)
                self.assertEqual(marker["directoryName"], root.name)
                self.assertEqual(
                    marker["activeTarget"],
                    f".neantik-notary.{transaction_id}",
                )
                self.assertIs(marker["externalEffectsAllowed"], False)
                self.assertEqual(
                    stat.S_IMODE(marker_path.stat().st_mode),
                    0o400,
                )
                self.assertEqual(
                    stat.S_IMODE(
                        (root / ".init-lease").stat().st_mode
                    ),
                    0o600,
                )
            finally:
                os.close(lease_descriptor)
                os.close(coordinator_descriptor)
                os.close(root_descriptor)

    def test_process_death_after_init_marker_blocks_without_cleanup(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir(mode=0o700)
            code = (
                "import os,sys;"
                f"sys.path.insert(0,{str(SCRIPT.parent)!r});"
                "import notarize_direct_transaction as m;"
                f"r,*_=m.create_initial_transaction_root("
                f"__import__('pathlib').Path({str(dist)!r}));"
                "print(r,flush=True);os._exit(97)"
            )
            completed = subprocess.run(
                [sys.executable, "-I", "-B", "-c", code],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(completed.returncode, 97)
            abandoned = Path(completed.stdout.strip())
            self.assertTrue((abandoned / ".init-marker.json").is_file())
            self.assertTrue((abandoned / ".init-lease").is_file())
            sentinel = abandoned / "sentinel"
            sentinel.write_text("keep", encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "operator reconciliation",
            ):
                MODULE.create_initial_transaction_root(dist)

            self.assertEqual(
                sentinel.read_text(encoding="utf-8"),
                "keep",
            )

    def test_submit_unknown_state_is_retained_without_history_match(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            first_runner = FakeReleaseRunner(fail_submit=True)
            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "submission",
            ):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=first_runner,
                    **self.source_kwargs(root),
                )
            active = MODULE.STATE.find_active_transaction(
                root / "dist",
                "NeAntik-1.2.3-arm64-notarized.zip",
            )
            self.assertIsNotNone(active)
            assert active is not None
            self.assertEqual(active[1][-1].stage, "submit-intent")

            second_runner = FakeReleaseRunner()
            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "notary history",
            ):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=second_runner,
                    **self.source_kwargs(root),
                )
            self.assertFalse(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "submit"]
                    for command in second_runner.commands
                )
            )

    def test_submit_intent_recovers_from_notary_history_without_resubmit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            first_runner = FakeReleaseRunner(fail_submit=True)
            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "submission",
            ):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=first_runner,
                    **self.source_kwargs(root),
                )
            active = MODULE.STATE.find_active_transaction(
                root / "dist",
                "NeAntik-1.2.3-arm64-notarized.zip",
            )
            self.assertIsNotNone(active)
            assert active is not None
            created = MODULE._receipt_data(active[1], "transaction-created")
            submission_name = created["submissionName"]
            self.assertIsInstance(submission_name, str)

            second_runner = FakeReleaseRunner(
                history_submission_name=submission_name,
            )
            result = MODULE.run_transaction(
                project_root=root,
                app=paths["app"],
                manifest=paths["manifest"],
                evidence=paths["evidence"],
                attestation=paths["attestation"],
                release_channel="public-alpha",
                notary_profile="test-profile",
                runner=second_runner,
                **self.source_kwargs(root),
            )

            self.assertEqual(result["submissionId"], SUBMISSION_ID)
            self.assertTrue(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "history"]
                    for command in second_runner.commands
                )
            )
            self.assertFalse(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "submit"]
                    for command in second_runner.commands
                )
            )

    def test_sidecar_crash_resumes_exact_transaction_without_resubmit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)

            def crash_after_sidecar(
                phase: str,
                _context: dict[str, Path],
            ) -> None:
                if phase == "sidecar-published":
                    raise RuntimeError("simulated crash boundary")

            with self.assertRaisesRegex(RuntimeError, "simulated"):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=FakeReleaseRunner(),
                    phase_hook=crash_after_sidecar,
                    **self.source_kwargs(root),
                )
            archive = (
                root / "dist" / "NeAntik-1.2.3-arm64-notarized.zip"
            )
            checksum = archive.with_name(archive.name + ".sha256")
            self.assertFalse(archive.exists())
            self.assertTrue(checksum.exists())
            active = MODULE.STATE.find_active_transaction(
                root / "dist",
                archive.name,
            )
            self.assertIsNotNone(active)
            assert active is not None
            self.assertEqual(active[1][-1].stage, "final-verified")

            second_runner = FakeReleaseRunner()
            recovered = MODULE.run_transaction(
                project_root=root,
                app=paths["app"],
                manifest=paths["manifest"],
                evidence=paths["evidence"],
                attestation=paths["attestation"],
                release_channel="public-alpha",
                notary_profile="test-profile",
                runner=second_runner,
                **self.source_kwargs(root),
            )
            self.assertFalse(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "submit"]
                    for command in second_runner.commands
                )
            )
            self.assertEqual(
                Path(recovered["archive"]).resolve(),
                archive.resolve(),
            )
            self.assertTrue(archive.exists())
            self.assertTrue(checksum.exists())
            self.assertIsNone(
                MODULE.STATE.find_active_transaction(
                    root / "dist",
                    archive.name,
                )
            )

    def test_activation_fsync_failure_cleans_canonical_transaction(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            original_fsync = MODULE.os.fsync
            injected = False

            def fail_after_activation(descriptor: int) -> None:
                nonlocal injected
                active_exists = any(
                    (root / "dist").glob(".neantik-notary.*")
                )
                if active_exists and not injected:
                    injected = True
                    raise OSError("simulated dist fsync failure")
                original_fsync(descriptor)

            with mock.patch.object(
                MODULE.os,
                "fsync",
                side_effect=fail_after_activation,
            ):
                with self.assertRaisesRegex(
                    MODULE.DirectNotaryTransactionError,
                    "failed",
                ):
                    MODULE.run_transaction(
                        project_root=root,
                        app=paths["app"],
                        manifest=paths["manifest"],
                        evidence=paths["evidence"],
                        attestation=paths["attestation"],
                        release_channel="public-alpha",
                        notary_profile="test-profile",
                        runner=FakeReleaseRunner(),
                        **self.source_kwargs(root),
                    )

            self.assertTrue(injected)
            self.assertEqual(
                list((root / "dist").glob(".neantik-notary.*")),
                [],
            )

    def test_activation_source_swap_fails_before_apple_submission(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            runner = FakeReleaseRunner()
            replacement: Path | None = None

            def swap_source(
                phase: str,
                context: dict[str, Path],
            ) -> None:
                nonlocal replacement
                if phase != "before-activation":
                    return
                source = context["transaction"]
                backup = source.with_name(source.name + ".owner")
                source.rename(backup)
                source.mkdir(mode=0o700)
                (source / "sentinel").write_text(
                    "foreign",
                    encoding="utf-8",
                )
                replacement = source

            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "identity is invalid",
            ):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=runner,
                    phase_hook=swap_source,
                    **self.source_kwargs(root),
                )

            self.assertIsNotNone(replacement)
            active = list(
                (root / "dist").glob(".neantik-notary.*")
            )
            self.assertEqual(len(active), 1)
            self.assertEqual(
                (active[0] / "sentinel").read_text(encoding="utf-8"),
                "foreign",
            )
            self.assertFalse(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "submit"]
                    for command in runner.commands
                )
            )

    def test_retirement_reports_post_rename_durability_failure(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / ".neantik-notary.original"
            transaction.mkdir(mode=0o700)
            status = transaction.stat(follow_symlinks=False)
            descriptor = os.open(
                transaction,
                os.O_RDONLY | os.O_DIRECTORY,
            )
            with mock.patch.object(
                MODULE.os,
                "fsync",
                side_effect=OSError("simulated durability failure"),
            ):
                retirement = MODULE.retire_exact_transaction(
                    transaction,
                    descriptor=descriptor,
                    expected_device=status.st_dev,
                    expected_inode=status.st_ino,
                )
            os.close(descriptor)

            self.assertTrue(retirement.moved)
            self.assertFalse(retirement.durable)
            self.assertFalse(retirement.verified)
            self.assertIsNotNone(retirement.destination)
            assert retirement.destination is not None
            self.assertTrue(retirement.destination.is_dir())
            self.assertFalse(transaction.exists())

    def test_marker_failure_quarantines_initial_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir(mode=0o700)
            with mock.patch.object(
                MODULE,
                "write_private_json",
                side_effect=OSError("simulated marker failure"),
            ):
                with self.assertRaisesRegex(OSError, "marker failure"):
                    MODULE.create_initial_transaction_root(dist)

            self.assertEqual(
                list(dist.glob(".neantik-notary-init.*")),
                [],
            )
            retired = list((dist / ".notary-retired").iterdir())
            self.assertEqual(len(retired), 1)
            self.assertTrue(retired[0].is_dir())

    def test_initial_root_open_failure_retries_and_quarantines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary) / "dist"
            dist.mkdir(mode=0o700)
            real_open = MODULE.os.open
            injected = False

            def fail_first_root_open(
                path: object,
                flags: int,
                *args: object,
                **kwargs: object,
            ) -> int:
                nonlocal injected
                name = os.fsdecode(path)
                if (
                    not injected
                    and name.startswith(".neantik-notary-init.")
                ):
                    injected = True
                    raise OSError("simulated root open failure")
                return real_open(path, flags, *args, **kwargs)

            with mock.patch.object(
                MODULE.os,
                "open",
                side_effect=fail_first_root_open,
            ):
                with self.assertRaisesRegex(
                    OSError,
                    "root open failure",
                ):
                    MODULE.create_initial_transaction_root(dist)

            self.assertTrue(injected)
            self.assertEqual(
                list(dist.glob(".neantik-notary-init.*")),
                [],
            )
            retired = list((dist / ".notary-retired").iterdir())
            self.assertEqual(len(retired), 1)
            self.assertTrue(retired[0].is_dir())

    def test_publication_hooks_cannot_mutate_committed_artifacts(
        self,
    ) -> None:
        cases = (
            (
                "sidecar-published",
                "NeAntik-1.2.3-arm64-notarized.zip.sha256",
            ),
            (
                "archive-published",
                "NeAntik-1.2.3-arm64-notarized.zip",
            ),
            (
                "published",
                "NeAntik-1.2.3-arm64-notarized.zip",
            ),
        )
        for phase_to_mutate, public_name in cases:
            with self.subTest(phase=phase_to_mutate):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    paths = self.fixture(root)

                    def mutate_public_artifact(
                        phase: str,
                        _context: dict[str, Path],
                    ) -> None:
                        if phase != phase_to_mutate:
                            return
                        public = root / "dist" / public_name
                        public.chmod(0o600)
                        public.write_bytes(b"ATTACKER-BYTES")

                    with self.assertRaisesRegex(
                        MODULE.DirectNotaryTransactionError,
                        "changed",
                    ):
                        MODULE.run_transaction(
                            project_root=root,
                            app=paths["app"],
                            manifest=paths["manifest"],
                            evidence=paths["evidence"],
                            attestation=paths["attestation"],
                            release_channel="public-alpha",
                            notary_profile="test-profile",
                            runner=FakeReleaseRunner(),
                            phase_hook=mutate_public_artifact,
                            **self.source_kwargs(root),
                        )
                    self.assertEqual(
                        (root / "dist" / public_name).read_bytes(),
                        b"ATTACKER-BYTES",
                    )
                    active = MODULE.STATE.find_active_transaction(
                        root / "dist",
                        "NeAntik-1.2.3-arm64-notarized.zip",
                    )
                    self.assertIsNotNone(active)

    def test_known_submission_resumes_by_id_without_second_submit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)

            def crash_after_submission_id(
                phase: str,
                _context: dict[str, Path],
            ) -> None:
                if phase == "submission-known":
                    raise RuntimeError("known submission crash")

            with self.assertRaisesRegex(RuntimeError, "known submission"):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=FakeReleaseRunner(),
                    phase_hook=crash_after_submission_id,
                    **self.source_kwargs(root),
                )
            active = MODULE.STATE.find_active_transaction(
                root / "dist",
                "NeAntik-1.2.3-arm64-notarized.zip",
            )
            self.assertIsNotNone(active)
            assert active is not None
            self.assertEqual(active[1][-1].stage, "submission-known")

            recovery_runner = FakeReleaseRunner()
            result = MODULE.run_transaction(
                project_root=root,
                app=paths["app"],
                manifest=paths["manifest"],
                evidence=paths["evidence"],
                attestation=paths["attestation"],
                release_channel="public-alpha",
                notary_profile="test-profile",
                runner=recovery_runner,
                **self.source_kwargs(root),
            )
            self.assertTrue(Path(result["archive"]).exists())
            self.assertFalse(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "submit"]
                    for command in recovery_runner.commands
                )
            )
            self.assertTrue(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "wait"]
                    for command in recovery_runner.commands
                )
            )

    def test_recovery_rejects_a_different_clean_git_commit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)

            def crash_after_submission_id(
                phase: str,
                _context: dict[str, Path],
            ) -> None:
                if phase == "submission-known":
                    raise RuntimeError("known submission crash")

            with self.assertRaises(RuntimeError):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=FakeReleaseRunner(),
                    phase_hook=crash_after_submission_id,
                    **self.source_kwargs(root),
                )
            recovery_runner = FakeReleaseRunner()
            with self.assertRaisesRegex(
                MODULE.DirectNotaryTransactionError,
                "does not match",
            ):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=recovery_runner,
                    **self.source_kwargs(root, commit="d"),
                )
            self.assertFalse(
                any(
                    command[:3]
                    in (
                        ["xcrun", "notarytool", "submit"],
                        ["xcrun", "notarytool", "wait"],
                        ["xcrun", "notarytool", "info"],
                    )
                    for command in recovery_runner.commands
                )
            )

    def test_public_zip_crash_is_adopted_without_apple_or_stapler(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)

            def crash_after_archive(
                phase: str,
                _context: dict[str, Path],
            ) -> None:
                if phase == "archive-published":
                    raise RuntimeError("archive commit crash")

            with self.assertRaisesRegex(RuntimeError, "archive commit"):
                MODULE.run_transaction(
                    project_root=root,
                    app=paths["app"],
                    manifest=paths["manifest"],
                    evidence=paths["evidence"],
                    attestation=paths["attestation"],
                    release_channel="public-alpha",
                    notary_profile="test-profile",
                    runner=FakeReleaseRunner(),
                    phase_hook=crash_after_archive,
                    **self.source_kwargs(root),
                )
            archive = (
                root / "dist" / "NeAntik-1.2.3-arm64-notarized.zip"
            )
            self.assertTrue(archive.exists())
            active = MODULE.STATE.find_active_transaction(
                root / "dist",
                archive.name,
            )
            self.assertIsNotNone(active)
            assert active is not None
            self.assertEqual(active[1][-1].stage, "sidecar-committed")

            recovery_runner = FakeReleaseRunner()
            result = MODULE.run_transaction(
                project_root=root,
                app=paths["app"],
                manifest=paths["manifest"],
                evidence=paths["evidence"],
                attestation=paths["attestation"],
                release_channel="public-alpha",
                notary_profile="test-profile",
                runner=recovery_runner,
                **self.source_kwargs(root),
            )
            self.assertTrue(Path(result["archive"]).exists())
            self.assertFalse(
                any(
                    tuple(command[:3])
                    in {
                        ("xcrun", "notarytool", "submit"),
                        ("xcrun", "notarytool", "wait"),
                        ("xcrun", "stapler", "staple"),
                    }
                    for command in recovery_runner.commands
                )
            )

    def test_process_death_after_sidecar_is_resumable(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self.fixture(root)
            code = """
import os
import sys
from pathlib import Path
from scripts.tests.test_notarize_direct_transaction import (
    DirectNotaryTransactionTests,
    FakeReleaseRunner,
    MODULE,
)
root = Path(sys.argv[1])
paths = {
    "app": root / "dist" / "NeAntik.app",
    "manifest": root / "dist" / "direct-candidate-manifest.json",
    "evidence": root / "dist" / "fingerprint-audit.json",
    "attestation": root / "dist" / "fingerprint-audit-summary.json",
}
def crash(phase, _context):
    if phase == "sidecar-published":
        os._exit(97)
MODULE.run_transaction(
    project_root=root,
    app=paths["app"],
    manifest=paths["manifest"],
    evidence=paths["evidence"],
    attestation=paths["attestation"],
    release_channel="public-alpha",
    notary_profile="test-profile",
    runner=FakeReleaseRunner(),
    phase_hook=crash,
    **DirectNotaryTransactionTests().source_kwargs(root),
)
"""
            completed = subprocess.run(
                [sys.executable, "-c", code, str(root)],
                cwd=SCRIPTS.parent,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
            )
            self.assertEqual(completed.returncode, 97)
            archive = (
                root / "dist" / "NeAntik-1.2.3-arm64-notarized.zip"
            )
            self.assertFalse(archive.exists())
            self.assertTrue(
                archive.with_name(archive.name + ".sha256").exists()
            )

            recovery_runner = FakeReleaseRunner()
            result = MODULE.run_transaction(
                project_root=root,
                app=paths["app"],
                manifest=paths["manifest"],
                evidence=paths["evidence"],
                attestation=paths["attestation"],
                release_channel="public-alpha",
                notary_profile="test-profile",
                runner=recovery_runner,
                **self.source_kwargs(root),
            )
            self.assertTrue(Path(result["archive"]).exists())
            self.assertFalse(
                any(
                    command[:3]
                    == ["xcrun", "notarytool", "submit"]
                    for command in recovery_runner.commands
                )
            )


if __name__ == "__main__":
    unittest.main()
