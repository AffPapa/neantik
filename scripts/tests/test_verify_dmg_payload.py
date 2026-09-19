import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('dmg_payload', Path(__file__).parents[1] / 'verify_dmg_payload.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DMGPayloadTests(unittest.TestCase):
    def test_exact_layout_and_extra_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'NeAntik.app').mkdir()
            (root / 'Applications').symlink_to('/Applications')
            MODULE.verify(root)
            (root / 'private-canary.txt').write_text('synthetic private data')
            with self.assertRaises(ValueError):
                MODULE.verify(root)

    def test_app_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'NeAntik.app').symlink_to('/Applications')
            (root / 'Applications').symlink_to('/Applications')
            with self.assertRaises(ValueError):
                MODULE.verify(root)

    def test_wrong_shortcut_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'NeAntik.app').mkdir()
            (root / 'Applications').symlink_to('/private/tmp')
            with self.assertRaises(ValueError):
                MODULE.verify(root)
