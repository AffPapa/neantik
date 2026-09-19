import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

SPEC = importlib.util.spec_from_file_location('upload', Path(__file__).parents[1] / 'upload_regular_release_file.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class UploadTests(unittest.TestCase):
    def test_rejects_symlink_before_transport(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'canary').write_bytes(b'PRIVATE SYNTHETIC CANARY')
            link = root / 'release.json'
            link.symlink_to(root / 'canary')
            with patch.object(MODULE.subprocess, 'run') as transport:
                with self.assertRaises(OSError):
                    MODULE.upload(link, ['mock-transport'])
                transport.assert_not_called()

    def test_regular_file_uses_open_descriptor_and_empty_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'release.json'
            path.write_bytes(b'{}')
            def receive(command, stdin, check):
                self.assertEqual(stdin.read(), b'{}')
                self.assertEqual(command, ['mock-transport', 'neantik-upload release.json'])
                return Mock(returncode=0)
            with patch.object(MODULE.subprocess, 'run', side_effect=receive):
                self.assertEqual(MODULE.upload(path, ['mock-transport']), 0)
            path.write_bytes(b'')
            with patch.object(MODULE.subprocess, 'run') as transport:
                with self.assertRaises(ValueError):
                    MODULE.upload(path, ['mock-transport'])
                transport.assert_not_called()

    def test_unsafe_filename_is_rejected(self):
        with patch.object(MODULE.subprocess, 'run') as transport:
            with self.assertRaises(ValueError):
                MODULE.upload('/unused/secret.txt', ['mock-transport'])
            transport.assert_not_called()

    def test_ancestor_symlink_rejected_before_transport(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            private = root / 'private'
            private.mkdir()
            (private / 'release.json').write_bytes(b'SYNTHETIC PRIVATE DATA')
            (root / 'alias').symlink_to(private, target_is_directory=True)
            with patch.object(MODULE.subprocess, 'run') as transport:
                with self.assertRaises(OSError):
                    MODULE.upload(root / 'alias' / 'release.json', ['mock-transport'])
                transport.assert_not_called()

    def test_parent_traversal_rejected_before_transport(self):
        with patch.object(MODULE.subprocess, 'run') as transport:
            with self.assertRaises(ValueError):
                MODULE.upload('/unused/../release.json', ['mock-transport'])
            transport.assert_not_called()
