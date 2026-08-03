import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release_input_snapshot.py"
SPEC = importlib.util.spec_from_file_location(
    "release_input_snapshot_tests",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ReleaseInputSnapshotTests(unittest.TestCase):
    def private_directory(self, root: Path, name: str) -> Path:
        path = root / name
        path.mkdir(mode=0o700)
        return path

    def test_snapshot_is_private_exact_and_detects_later_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.json"
            source.write_bytes(b'{"schemaVersion":8}\n')
            source.chmod(0o600)
            destination = self.private_directory(root, "txn") / "pinned.json"

            snapshot = MODULE.snapshot_release_input(
                source,
                destination,
                maximum_bytes=1024,
            )

            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
            MODULE.assert_snapshot_source_unchanged(
                snapshot,
                maximum_bytes=1024,
            )
            source.write_bytes(b'{"schemaVersion":9}\n')
            with self.assertRaisesRegex(
                MODULE.ReleaseInputSnapshotError,
                "changed after snapshot",
            ):
                MODULE.assert_snapshot_source_unchanged(
                    snapshot,
                    maximum_bytes=1024,
                )
            destination.write_bytes(b'{"schemaVersion":7}\n')
            with self.assertRaisesRegex(
                MODULE.ReleaseInputSnapshotError,
                "pinned release input changed",
            ):
                MODULE.assert_snapshot_copy_unchanged(
                    snapshot,
                    maximum_bytes=1024,
                )
            destination.write_bytes(b'{"schemaVersion":8}\n')
            with self.assertRaisesRegex(
                MODULE.ReleaseInputSnapshotError,
                "pinned release input changed",
            ):
                MODULE.assert_snapshot_copy_unchanged(
                    snapshot,
                    maximum_bytes=1024,
                )

    def test_rejects_symlink_hardlink_and_group_writable_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.write_bytes(b"release")
            target.chmod(0o600)
            destination_root = self.private_directory(root, "txn")

            symlink = root / "symlink"
            symlink.symlink_to(target)
            hardlink = root / "hardlink"
            os.link(target, hardlink)
            for index, source in enumerate((symlink, hardlink)):
                with self.assertRaises(MODULE.ReleaseInputSnapshotError):
                    MODULE.snapshot_release_input(
                        source,
                        destination_root / f"pinned-{index}",
                        maximum_bytes=1024,
                    )

            hardlink.unlink()
            target.chmod(0o620)
            with self.assertRaises(MODULE.ReleaseInputSnapshotError):
                MODULE.snapshot_release_input(
                    target,
                    destination_root / "pinned-group-writable",
                    maximum_bytes=1024,
                )

    def test_rejects_oversized_input_and_unsafe_destination_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.write_bytes(b"x" * 33)
            source.chmod(0o600)
            private = self.private_directory(root, "private")
            with self.assertRaisesRegex(
                MODULE.ReleaseInputSnapshotError,
                "size limit",
            ):
                MODULE.snapshot_release_input(
                    source,
                    private / "too-large",
                    maximum_bytes=32,
                )

            unsafe = root / "unsafe"
            unsafe.mkdir(mode=0o755)
            with self.assertRaisesRegex(
                MODULE.ReleaseInputSnapshotError,
                "directory is unsafe",
            ):
                MODULE.snapshot_release_input(
                    source,
                    unsafe / "pinned",
                    maximum_bytes=64,
                )

    def test_rejects_same_size_mutation_during_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.write_bytes(b"a" * (2 * 1024 * 1024))
            source.chmod(0o600)
            destination = self.private_directory(root, "txn") / "pinned"
            original_read = MODULE.os.read
            read_count = 0

            def mutating_read(descriptor: int, size: int) -> bytes:
                nonlocal read_count
                chunk = original_read(descriptor, size)
                read_count += 1
                if read_count == 1:
                    with source.open("r+b") as file:
                        file.seek(1024 * 1024 + 16)
                        file.write(b"b")
                        file.flush()
                        os.fsync(file.fileno())
                return chunk

            with mock.patch.object(
                MODULE.os,
                "read",
                side_effect=mutating_read,
            ):
                with self.assertRaisesRegex(
                    MODULE.ReleaseInputSnapshotError,
                    "changed during snapshot",
                ):
                    MODULE.snapshot_release_input(
                        source,
                        destination,
                        maximum_bytes=3 * 1024 * 1024,
                    )

            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
