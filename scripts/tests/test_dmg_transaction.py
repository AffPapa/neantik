"""Fault controls for continuation; fake Apple is not native notarization evidence."""
import hashlib
import json
import os
from pathlib import Path
import select
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dmg_contents
import notarize_dmg_transaction as dmg

IDENTIFIER = "11111111-2222-3333-4444-555555555555"


class SimulatedCrash(BaseException):
    pass


@unittest.skipUnless(hasattr(select, "kqueue"), "DMG custody requires macOS kqueue")
class DMGTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.project = self.base / "project"
        self.project.mkdir(mode=0o700)
        self.output = self.project / "dist"
        self.output.mkdir(mode=0o700)
        (self.output / "direct-candidate-manifest.json").write_text('{"releaseChannel":"public-alpha"}')
        self.destination = self.output / "NeAntik-9.1.0-arm64-notarized.dmg"
        self.prepared = self.base / self.destination.name
        self.prepared.write_bytes(b"signed DMG input")
        self.prepared.chmod(0o600)
        self.archive = self.base / self.destination.with_suffix(".zip").name
        self.archive.write_bytes(b"qualified ZIP input")
        self.archive.chmod(0o600)
        self.archive.with_name(self.archive.name + ".sha256").write_text(
            hashlib.sha256(self.archive.read_bytes()).hexdigest() + "  " + self.archive.name + "\n")
        self.root = self.output / "transaction"
        self.payload = {"source": "original"}
        self.capture = lambda *a, **k: SimpleNamespace(payload=dict(self.payload))
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(dmg.source, "assert_release_source_unchanged").start()
        self.commands = []
        self.qualifications = []
        self.submit_output = json.dumps({"id": IDENTIFIER, "status": "In Progress"})
        self.wait_output = json.dumps({"id": IDENTIFIER, "status": "Accepted"})
        self.fail_verify = False
        self.fail_staple = False
        dmg.start(self.root, self.project, self.destination, "QA-notary",
                  self.prepared, self.archive, capture=self.capture)

    def runner(self, command, project):
        self.commands.append(command)
        output, code = "", 0
        if command[:3] == ["xcrun", "notarytool", "history"]:
            output = '{"history": []}'
        elif command[:3] == ["xcrun", "notarytool", "submit"]:
            output = self.submit_output
        elif command[:3] == ["xcrun", "notarytool", "wait"]:
            output = self.wait_output
        elif command[:3] == ["xcrun", "notarytool", "log"]:
            image = self.root / "submitted" / self.destination.name
            output = json.dumps({"jobId": IDENTIFIER, "status": "Accepted", "statusCode": 0,
                                 "issues": None, "archiveFilename": self.destination.name,
                                 "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                                 "ticketContents": [{"path": self.destination.name + suffix,
                                     "cdhash": "a" * 40, "arch": "arm64"} for suffix in
                                     ("", "/NeAntik.app", "/NeAntik.app/Contents/Resources/NeAntik Browser.app")],
                                 "PRIVATE_FIELD": "must not be retained"})
        elif command[:3] == ["xcrun", "stapler", "staple"]:
            with Path(command[-1]).open("ab") as stream:
                stream.write(b" stapled")
            code = 1 if self.fail_staple else 0
        elif command[0].endswith("verify-direct-notarized-dmg.sh"):
            code = 1 if self.fail_verify else 0
        return dmg.notary.CommandResult(code, output, "PRIVATE output not for diagnostics")

    def qualify(self, project, image, archive, runner, manifest, channel):
        self.qualifications.append((image.read_bytes(), archive.read_bytes()))
        self.assertEqual(channel, "public-alpha")
        self.assertTrue(manifest.is_file())

    def continue_transaction(self, fault=lambda stage: None):
        return dmg.run(self.root, self.project, self.destination, "QA-notary",
                       runner=self.runner, capture=self.capture,
                       qualify=self.qualify, fault=fault)

    def count(self, action):
        return sum(command[:3] == ["xcrun", "notarytool", action] for command in self.commands)

    def interrupt(self, stage):
        def fault(actual):
            if actual == stage:
                raise SimulatedCrash()
        with self.assertRaises(SimulatedCrash):
            self.continue_transaction(fault)

    def test_complete_keeps_submission_and_idempotently_adopts_publication(self):
        self.continue_transaction()
        self.continue_transaction()
        self.assertEqual(self.count("submit"), 1)
        self.assertEqual(self.count("wait"), 1)
        self.assertEqual((self.root / "submitted" / self.destination.name).read_bytes(), b"signed DMG input")
        self.assertEqual(self.destination.read_bytes(), b"signed DMG input stapled")
        self.assertEqual(self.destination.stat().st_ino, (self.root / "final" / self.destination.name).stat().st_ino)
        self.assertEqual(len(self.qualifications), 2)

    def test_every_known_phase_resumes_without_resubmit(self):
        for stage in dmg.STAGES[1:] + ("stapled", "published-sidecar-committed", "published-dmg-committed"):
            with self.subTest(stage=stage):
                # Independent private transaction for each crash point.
                prior_root, prior_destination = self.root, self.destination
                case = self.output / stage
                case.mkdir(mode=0o700)
                self.root, self.destination = case / "transaction", case / prior_destination.name
                # Diagnostic outputs have the same legacy basename, so isolate dist too.
                original_project = self.project
                self.project = case / "project"
                (self.project / "dist").mkdir(mode=0o700, parents=True)
                (self.project / "dist/direct-candidate-manifest.json").write_text('{"releaseChannel":"public-alpha"}')
                self.commands = []
                dmg.start(self.root, self.project, self.destination, "QA-notary", self.prepared, self.archive, capture=self.capture)
                self.interrupt(stage)
                if stage == "submit-intent":
                    with self.assertRaisesRegex(dmg.DMGError, "uncertain"):
                        self.continue_transaction()
                    self.assertEqual(self.count("submit"), 0)
                else:
                    self.continue_transaction()
                    self.assertEqual(self.count("submit"), 1)
                    self.assertEqual(self.destination.read_bytes(), b"signed DMG input stapled")
                self.root, self.destination = prior_root, prior_destination
                self.project = original_project

    def test_failed_submit_response_does_not_automatically_resubmit(self):
        for index, output in enumerate(('{}', 'not JSON', '{"id":"bad"}',
                       '{"id":"' + IDENTIFIER + '","id":"' + IDENTIFIER + '"}')):
            with self.subTest(output=output):
                self.root = self.output / f"malformed-{index}"
                dmg.start(self.root, self.project, self.destination, "QA-notary", self.prepared, self.archive, capture=self.capture)
                self.commands = []
                self.submit_output = output
                with self.assertRaises(dmg.notary.DirectNotaryTransactionError):
                    self.continue_transaction()
                with self.assertRaisesRegex(dmg.DMGError, "uncertain"):
                    self.continue_transaction()
                self.assertEqual(self.count("submit"), 1)

    def test_invalid_or_wrong_id_wait_can_resume_known_submission(self):
        self.wait_output = json.dumps({"id": IDENTIFIER, "status": "Invalid"})
        with self.assertRaises(dmg.notary.DirectNotaryTransactionError):
            self.continue_transaction()
        self.wait_output = json.dumps({"id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "status": "Accepted"})
        with self.assertRaises(dmg.notary.DirectNotaryTransactionError):
            self.continue_transaction()
        self.wait_output = json.dumps({"id": IDENTIFIER, "status": "Accepted"})
        self.continue_transaction()
        self.assertEqual(self.count("submit"), 1)

    def test_partial_staple_and_verifier_failure_recreate_only_work_copy(self):
        self.fail_staple = True
        with self.assertRaises(dmg.DMGError):
            self.continue_transaction()
        self.fail_staple, self.fail_verify = False, True
        with self.assertRaises(dmg.DMGError):
            self.continue_transaction()
        self.fail_verify = False
        self.continue_transaction()
        self.assertEqual(self.count("submit"), 1)
        self.assertEqual(self.destination.read_bytes(), b"signed DMG input stapled")

    def test_truncated_unpromoted_work_copy_is_recreated(self):
        self.interrupt("stapled")
        (self.root / "final" / self.destination.name).write_bytes(b"")
        self.continue_transaction()
        self.assertEqual(self.destination.read_bytes(), b"signed DMG input stapled")
        self.assertEqual(self.count("submit"), 1)

    def test_changed_policy_or_invocation_refuses_before_apple(self):
        self.payload = {"source": "changed"}
        with self.assertRaisesRegex(dmg.DMGError, "source changed"):
            self.continue_transaction()
        self.assertEqual(self.commands, [])
        self.payload = {"source": "original"}
        with self.assertRaisesRegex(dmg.DMGError, "binding"):
            dmg.run(self.root, self.project, self.destination, "OTHER-notary", runner=self.runner, capture=self.capture)

    def test_changed_pinned_inputs_refuse(self):
        for folder, name in (("submitted", self.destination.name), ("archive", self.archive.name)):
            path = self.root / folder / name
            original = path.read_bytes()
            path.write_bytes(b"changed")
            with self.assertRaises(dmg.transaction.ReleaseTransactionError):
                self.continue_transaction()
            path.write_bytes(original)
        self.assertEqual(self.commands, [])

    def test_changed_original_zip_does_not_replace_pinned_zip(self):
        self.archive.write_bytes(b"ZIP from another candidate")
        self.continue_transaction()
        self.assertTrue(all(item[1] == b"qualified ZIP input" for item in self.qualifications))

    def test_changed_final_artifact_and_foreign_destination_refuse(self):
        self.interrupt("final-verified")
        final = self.root / "final" / self.destination.name
        final.write_bytes(b"changed final")
        with self.assertRaises(dmg.transaction.ReleaseTransactionError):
            self.continue_transaction()
        self.assertFalse(self.destination.exists())

    def test_foreign_destination_is_preserved(self):
        self.interrupt("final-verified")
        self.destination.write_bytes(b"immutable prior release")
        self.destination.chmod(0o600)
        with self.assertRaises(dmg.transaction.ReleaseTransactionError):
            self.continue_transaction()
        self.assertEqual(self.destination.read_bytes(), b"immutable prior release")

    def test_receipt_gap_change_symlink_and_hardlink_refuse(self):
        self.interrupt("submission-known")
        receipts = dmg.Receipts(self.root)
        path = receipts.path("qualified")
        retained = path.read_bytes()
        path.unlink()
        with self.assertRaisesRegex(dmg.DMGError, "gap"):
            dmg.Receipts(self.root)
        path.write_bytes(retained)
        path.chmod(0o400)
        path.unlink()
        path.symlink_to(receipts.path("created"))
        with self.assertRaises(dmg.transaction.ReleaseTransactionError):
            dmg.Receipts(self.root)
        path.unlink()
        os.link(receipts.path("created"), path)
        with self.assertRaises(dmg.transaction.ReleaseTransactionError):
            dmg.Receipts(self.root)

    def test_unsafe_work_copy_link_is_not_deleted(self):
        self.interrupt("accepted")
        final = self.root / "final" / self.destination.name
        final.symlink_to(self.prepared)
        with self.assertRaises(dmg.transaction.ReleaseTransactionError):
            self.continue_transaction()
        self.assertTrue(final.is_symlink())
        self.assertEqual(self.prepared.read_bytes(), b"signed DMG input")

    def test_same_name_transaction_has_one_owner(self):
        first = dmg.state.acquire_transaction_lock(self.output, self.destination.name)
        try:
            with self.assertRaises(dmg.state.NotaryTransactionStateError):
                dmg.state.acquire_transaction_lock(self.output, self.destination.name)
        finally:
            os.close(first)

    def test_new_cli_start_detects_existing_uncertain_or_complete_transaction(self):
        private = self.output / "private"
        private.mkdir(mode=0o700)
        root = private / ("a" * 32)
        dmg.start(root, self.project, self.destination, "QA-notary", self.prepared, self.archive, capture=self.capture)
        self.assertEqual(dmg.existing_transactions(private, self.destination), [root])
        self.assertEqual(dmg.existing_transactions(private, self.output / "different.dmg"), [])
        unknown = private / ("b" * 32)
        unknown.mkdir(mode=0o700)
        with self.assertRaisesRegex(dmg.DMGError, "Uninitialized"):
            dmg.existing_transactions(private, self.destination)

    def test_zip_sidecar_is_pinned_and_damage_is_rejected(self):
        path = self.root / "archive" / (self.archive.name + ".sha256")
        path.write_bytes(b"wrong checksum")
        with self.assertRaises(dmg.transaction.ReleaseTransactionError):
            self.continue_transaction()
        self.assertEqual(self.commands, [])

    def test_private_receipt_mode_and_alias_root_are_rejected(self):
        path = dmg.Receipts(self.root).path("created")
        path.chmod(0o644)
        with self.assertRaises(dmg.transaction.ReleaseTransactionError):
            dmg.Receipts(self.root)
        alias = self.output / "alias"
        alias.symlink_to(self.root)
        with self.assertRaises(dmg.DMGError):
            dmg.Receipts(alias)

    def test_apple_log_is_bound_and_private_fields_are_not_exported(self):
        self.continue_transaction()
        log = self.project / "dist/notary" / (self.destination.name + ".notary-receipt.json")
        payload = json.loads(log.read_text())
        self.assertNotIn("PRIVATE_FIELD", payload)
        payload["sha256"] = "0" * 64
        submitted = dmg.decode_seal(dmg.Receipts(self.root).data["submitted"], self.root / "submitted" / self.destination.name)
        with self.assertRaises(dmg.DMGError):
            dmg.validated_apple_log(json.dumps(payload), IDENTIFIER, submitted)


class DMGContentsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.app = self.base / "NeAntik.app"
        self.app.mkdir()
        (self.app / "file").write_bytes(b"accepted app")
        (self.app / "alias").symlink_to("file")
        self.archive = self.base / "app.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.write(self.app / "file", "NeAntik.app/file")
            link = zipfile.ZipInfo("NeAntik.app/alias")
            link.create_system = 3
            link.external_attr = (0o120777 << 16)
            archive.writestr(link, b"file")

    def test_real_zip_content_and_symlink_positive_and_mutations(self):
        dmg_contents.assert_app_matches_zip(self.app, self.archive)
        (self.app / "file").write_bytes(b"different app")
        with self.assertRaises(ValueError):
            dmg_contents.assert_app_matches_zip(self.app, self.archive)
        (self.app / "file").write_bytes(b"accepted app")
        (self.app / "alias").unlink()
        (self.app / "alias").symlink_to("other")
        with self.assertRaises(ValueError):
            dmg_contents.assert_app_matches_zip(self.app, self.archive)

    def test_missing_extra_executable_or_unsafe_paths_are_not_equivalent(self):
        (self.app / "extra").write_bytes(b"extra")
        with self.assertRaises(ValueError):
            dmg_contents.assert_app_matches_zip(self.app, self.archive)
        (self.app / "extra").unlink()
        (self.app / "file").chmod(0o755)
        with self.assertRaises(ValueError):
            dmg_contents.assert_app_matches_zip(self.app, self.archive)
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("NeAntik.app/../escape", b"bad")
        with self.assertRaises(ValueError):
            dmg_contents.assert_app_matches_zip(self.app, self.archive)

    def test_root_inventory_rejects_extra_hidden_files_apps_and_links(self):
        (self.base / "Applications").symlink_to("/Applications")
        # The ZIP itself is outside a real mounted volume; remove this fixture file.
        self.archive.unlink()
        dmg_contents.assert_volume_inventory(self.base)
        for name in ("debug.txt", ".private.env", "Extra.app", "other-link"):
            path = self.base / name
            if name.endswith(".app"):
                path.mkdir()
            elif name.endswith("link"):
                path.symlink_to("/tmp")
            else:
                path.write_bytes(b"unreviewed")
            with self.assertRaises(ValueError):
                dmg_contents.assert_volume_inventory(self.base)
            if path.is_dir() and not path.is_symlink():
                path.rmdir()
            else:
                path.unlink()


if __name__ == "__main__":
    unittest.main()
