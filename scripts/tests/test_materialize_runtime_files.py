import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "materialize-runtime-files.py"


class MaterializeRuntimeFilesTests(unittest.TestCase):
    def test_breaks_external_hardlink_and_preserves_bytes_mode_and_xattrs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "Runtime.app"
            (runtime / "Contents" / "MacOS").mkdir(parents=True)
            staged = runtime / "Contents" / "MacOS" / "Browser"
            source = root / "build-output"
            source.write_bytes(b"signed runtime bytes")
            source.chmod(0o755)
            os.link(source, staged)
            before = staged.stat()
            self.assertEqual(before.st_nlink, 2)

            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(runtime)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(staged.read_bytes(), b"signed runtime bytes")
            self.assertEqual(staged.stat().st_mode & 0o777, 0o755)
            self.assertEqual(staged.stat().st_nlink, 1)
            self.assertEqual(source.stat().st_nlink, 1)
            self.assertIn("materialized linked runtime files: 1", result.stdout)

    def test_leaves_symlinks_and_single_link_files_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary) / "Runtime.app"
            runtime.mkdir()
            regular = runtime / "regular"
            regular.write_bytes(b"same inode")
            link = runtime / "alias"
            link.symlink_to("regular")
            before = regular.stat().st_ino

            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(runtime)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(regular.stat().st_ino, before)
            self.assertTrue(link.is_symlink())
            self.assertIn("materialized linked runtime files: 0", result.stdout)


if __name__ == "__main__":
    unittest.main()
