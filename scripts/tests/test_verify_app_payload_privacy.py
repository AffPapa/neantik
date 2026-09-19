import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('payload', Path(__file__).parents[1] / 'verify_app_payload_privacy.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PayloadPrivacyTests(unittest.TestCase):
    def test_private_files_rejected(self):
        for name in ('.env', 'Default/Cookies', 'Login Data', 'signing.p8'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'synthetic')
                with self.assertRaises(ValueError):
                    MODULE.verify(Path(directory))

    def test_framework_symlink_allowed_but_escape_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Versions/A').mkdir(parents=True)
            (root / 'Versions/A/binary').write_bytes(b'public binary')
            (root / 'Versions/Current').symlink_to('A')
            self.assertEqual(MODULE.verify(root), 1)
            (root / 'external').symlink_to('/Applications')
            with self.assertRaises(ValueError):
                MODULE.verify(root)

    def test_content_secret_crossing_chunk_boundary_is_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            token = b'ghp_' + b'SyntheticOnlyNotRealCredential12345'
            (root / 'resource.dat').write_bytes(b'x' * (1024 * 1024 - 3) + b'\n' + token)
            with self.assertRaises(ValueError) as caught:
                MODULE.verify(root)
            self.assertNotIn(token.decode(), str(caught.exception))
