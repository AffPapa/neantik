import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = (
    Path(__file__).resolve().parents[1] / "release_transaction.py"
)
SPEC = importlib.util.spec_from_file_location(
    "release_transaction",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ReleaseTransactionTests(unittest.TestCase):
    def write_private(
        self,
        path: Path,
        payload: bytes,
    ) -> None:
        path.write_bytes(payload)
        path.chmod(0o600)

    def test_seal_rejects_mutation_symlink_and_hardlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "candidate.zip"
            self.write_private(artifact, b"candidate-a")
            seal = MODULE.seal_regular_file(
                artifact,
                maximum_bytes=1024,
            )
            MODULE.assert_sealed(seal, maximum_bytes=1024)

            self.write_private(artifact, b"candidate-b")
            with self.assertRaisesRegex(
                MODULE.ReleaseTransactionError,
                "changed",
            ):
                MODULE.assert_sealed(seal, maximum_bytes=1024)

            symlink = root / "candidate-link.zip"
            symlink.symlink_to(artifact)
            with self.assertRaises(MODULE.ReleaseTransactionError):
                MODULE.seal_regular_file(
                    symlink,
                    maximum_bytes=1024,
                )

            hardlink = root / "candidate-hardlink.zip"
            os.link(artifact, hardlink)
            with self.assertRaisesRegex(
                MODULE.ReleaseTransactionError,
                "changed",
            ):
                MODULE.seal_regular_file(
                    artifact,
                    maximum_bytes=1024,
                )

    @unittest.skipUnless(
        hasattr(__import__("select"), "kqueue"),
        "release observation requires macOS kqueue",
    )
    def test_observer_detects_write_restore_during_phase(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "candidate.zip"
            self.write_private(artifact, b"candidate-a")
            seal = MODULE.seal_regular_file(
                artifact,
                maximum_bytes=1024,
            )

            def mutate_and_restore() -> None:
                self.write_private(artifact, b"candidate-b")
                self.write_private(artifact, b"candidate-a")

            with self.assertRaisesRegex(
                MODULE.ReleaseTransactionError,
                "changed during",
            ):
                MODULE.observe_sealed_phase(
                    seal,
                    mutate_and_restore,
                    maximum_bytes=1024,
                )

    def test_checksum_and_no_clobber_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / "transaction"
            transaction.mkdir(mode=0o700)
            dist = root / "dist"
            dist.mkdir(mode=0o700)
            archive = transaction / "NeAntik-1.2.3-arm64-notarized.zip"
            self.write_private(archive, b"notarized candidate")
            archive_seal = MODULE.seal_regular_file(
                archive,
                maximum_bytes=1024,
            )
            checksum = transaction / (archive.name + ".sha256")
            checksum_seal = MODULE.write_checksum_sidecar(
                archive_seal,
                checksum,
            )
            self.assertEqual(
                checksum.read_text(encoding="utf-8"),
                f"{archive_seal.sha256}  {archive.name}\n",
            )

            final_archive = dist / archive.name
            final_checksum = dist / checksum.name
            MODULE.publish_release_pair(
                archive_seal,
                checksum_seal,
                archive_destination=final_archive,
                checksum_destination=final_checksum,
                maximum_archive_bytes=1024,
            )
            self.assertEqual(final_archive.read_bytes(), archive.read_bytes())
            self.assertEqual(
                final_checksum.read_bytes(),
                checksum.read_bytes(),
            )
            self.assertEqual(
                final_archive.stat().st_ino,
                archive.stat().st_ino,
            )

    def test_publication_refuses_collision_and_rolls_back_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / "transaction"
            transaction.mkdir(mode=0o700)
            dist = root / "dist"
            dist.mkdir(mode=0o700)
            archive = transaction / "NeAntik-1.2.3-arm64-notarized.zip"
            self.write_private(archive, b"transaction candidate")
            archive_seal = MODULE.seal_regular_file(
                archive,
                maximum_bytes=1024,
            )
            checksum = transaction / (archive.name + ".sha256")
            checksum_seal = MODULE.write_checksum_sidecar(
                archive_seal,
                checksum,
            )
            final_archive = dist / archive.name
            self.write_private(final_archive, b"unrelated release")
            final_checksum = dist / checksum.name

            with self.assertRaisesRegex(
                MODULE.ReleaseTransactionError,
                "already exists",
            ):
                MODULE.publish_release_pair(
                    archive_seal,
                    checksum_seal,
                    archive_destination=final_archive,
                    checksum_destination=final_checksum,
                    maximum_archive_bytes=1024,
                )

            self.assertEqual(
                final_archive.read_bytes(),
                b"unrelated release",
            )
            self.assertFalse(final_checksum.exists())

    def test_publication_rejects_malformed_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / "transaction"
            transaction.mkdir(mode=0o700)
            dist = root / "dist"
            dist.mkdir(mode=0o700)
            archive = transaction / "NeAntik-1.2.3-arm64-notarized.zip"
            self.write_private(archive, b"transaction candidate")
            archive_seal = MODULE.seal_regular_file(
                archive,
                maximum_bytes=1024,
            )
            checksum = transaction / (archive.name + ".sha256")
            self.write_private(checksum, b"wrong\n")
            checksum_seal = MODULE.seal_regular_file(
                checksum,
                maximum_bytes=1024,
            )

            with self.assertRaisesRegex(
                MODULE.ReleaseTransactionError,
                "does not match",
            ):
                MODULE.publish_release_pair(
                    archive_seal,
                    checksum_seal,
                    archive_destination=dist / archive.name,
                    checksum_destination=dist / checksum.name,
                    maximum_archive_bytes=1024,
                )

    def test_source_swap_during_link_never_reaches_public_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / "transaction"
            transaction.mkdir(mode=0o700)
            dist = root / "dist"
            dist.mkdir(mode=0o700)
            archive = transaction / "NeAntik-1.2.3-arm64-notarized.zip"
            self.write_private(archive, b"transaction candidate")
            archive_seal = MODULE.seal_regular_file(
                archive,
                maximum_bytes=1024,
            )
            checksum = transaction / (archive.name + ".sha256")
            checksum_seal = MODULE.write_checksum_sidecar(
                archive_seal,
                checksum,
            )
            original_link = MODULE.os.link

            def swap_archive_for_link(
                source,
                destination,
                *,
                src_dir_fd=None,
                dst_dir_fd=None,
                follow_symlinks=True,
            ):
                if source == archive.name:
                    backup = transaction / "candidate.backup"
                    archive.rename(backup)
                    self.write_private(archive, b"ATTACKER")
                    try:
                        return original_link(
                            source,
                            destination,
                            src_dir_fd=src_dir_fd,
                            dst_dir_fd=dst_dir_fd,
                            follow_symlinks=follow_symlinks,
                        )
                    finally:
                        archive.unlink()
                        backup.rename(archive)
                return original_link(
                    source,
                    destination,
                    src_dir_fd=src_dir_fd,
                    dst_dir_fd=dst_dir_fd,
                    follow_symlinks=follow_symlinks,
                )

            with mock.patch.object(
                MODULE.os,
                "link",
                side_effect=swap_archive_for_link,
            ):
                with self.assertRaisesRegex(
                    MODULE.ReleaseTransactionError,
                    "immediately before publication",
                ):
                    MODULE.publish_release_pair(
                        archive_seal,
                        checksum_seal,
                        archive_destination=dist / archive.name,
                        checksum_destination=dist / checksum.name,
                        maximum_archive_bytes=1024,
                    )

            self.assertFalse((dist / archive.name).exists())
            self.assertFalse((dist / checksum.name).exists())
            self.assertEqual(archive.read_bytes(), b"transaction candidate")

    def test_hidden_swap_before_exclusive_rename_is_rolled_back(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / "transaction"
            transaction.mkdir(mode=0o700)
            dist = root / "dist"
            dist.mkdir(mode=0o700)
            archive = transaction / "NeAntik-1.2.3-arm64-notarized.zip"
            self.write_private(archive, b"transaction candidate")
            archive_seal = MODULE.seal_regular_file(
                archive,
                maximum_bytes=1024,
            )
            checksum = transaction / (archive.name + ".sha256")
            checksum_seal = MODULE.write_checksum_sidecar(
                archive_seal,
                checksum,
            )
            original_rename = MODULE._rename_exclusive

            def swap_hidden_before_rename(
                source_parent,
                source_name,
                destination_parent,
                destination_name,
            ):
                if destination_name == archive.name:
                    hidden = dist / source_name
                    backup = dist / (source_name + ".backup")
                    hidden.rename(backup)
                    self.write_private(hidden, b"ATTACKER")
                    try:
                        return original_rename(
                            source_parent,
                            source_name,
                            destination_parent,
                            destination_name,
                        )
                    finally:
                        backup.rename(hidden)
                return original_rename(
                    source_parent,
                    source_name,
                    destination_parent,
                    destination_name,
                )

            with mock.patch.object(
                MODULE,
                "_rename_exclusive",
                side_effect=swap_hidden_before_rename,
            ):
                with self.assertRaises(
                    MODULE.ReleaseTransactionError
                ):
                    MODULE.publish_release_pair(
                        archive_seal,
                        checksum_seal,
                        archive_destination=dist / archive.name,
                        checksum_destination=dist / checksum.name,
                        maximum_archive_bytes=1024,
                    )

            self.assertFalse((dist / archive.name).exists())
            self.assertFalse((dist / checksum.name).exists())
            self.assertEqual(
                list(dist.glob(".*.neantik-publish-*")),
                [],
            )


if __name__ == "__main__":
    unittest.main()
