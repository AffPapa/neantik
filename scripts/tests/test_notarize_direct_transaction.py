import importlib.util
import json
import os
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile
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
    ) -> None:
        self.commands: list[list[str]] = []
        self.mutate_during_submit = mutate_during_submit
        self.notary_status = notary_status
        self.info_identifier = info_identifier
        self.fail_final_verifier = fail_final_verifier

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
        self.assertIn("/accepted/NeAntik.app", staple[3])
        self.assertEqual(receipt["appleSubmission"]["status"], "Accepted")
        self.assertEqual(receipt["appleSubmission"]["id"], SUBMISSION_ID)
        self.assertEqual(receipt["finalArchive"]["sha256"], result["sha256"])
        self.assertEqual(receipt["publicationState"], "transaction-verified")
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

            MODULE.cleanup_exact_transaction(
                transaction,
                descriptor=descriptor,
                expected_device=status.st_dev,
                expected_inode=status.st_ino,
            )
            os.close(descriptor)

            self.assertEqual(
                sentinel.read_text(encoding="utf-8"),
                "keep",
            )


if __name__ == "__main__":
    unittest.main()
