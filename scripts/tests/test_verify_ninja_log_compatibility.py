from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_ninja_log_compatibility as subject


class NinjaLogCompatibilityTests(unittest.TestCase):
    def check_version(self, version, root):
        with patch.object(subject.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, version+'\n', '')):
            subject.verify(Path('/fixture/ninja'), root)

    def test_expected_versions_preserve_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for version, format_version in [('1.12.1', 6), ('1.13.0', 7), ('1.13.2', 7)]:
                data = f'# ninja log v{format_version}\nfixture\n'.encode()
                (root / '.ninja_log').write_bytes(data)
                self.check_version(version, root)
                self.assertEqual((root / '.ninja_log').read_bytes(), data)

    def test_mismatches_and_corruption_rejected_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for version, data in [('1.12.1', b'# ninja log v7\nfixture'), ('1.13.2', b'# ninja log v6\nfixture'), ('1.13.2', b'corrupt')]:
                (root / '.ninja_log').write_bytes(data)
                with self.assertRaises(ValueError):
                    self.check_version(version, root)
                self.assertEqual((root / '.ninja_log').read_bytes(), data)

    def test_absent_log_allowed_but_unknown_tool_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.check_version('1.13.2', root)
            with self.assertRaises(ValueError):
                self.check_version('1.14.0', root)
            self.assertFalse((root / '.ninja_log').exists())

    def test_symlink_log_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.ninja_log').symlink_to(root / 'missing')
            with self.assertRaises(ValueError):
                self.check_version('1.13.2', root)
