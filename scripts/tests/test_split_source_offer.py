import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'split-source-offer.py'
SPEC = importlib.util.spec_from_file_location('split_source_offer', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SplitSourceOfferTests(unittest.TestCase):
    def test_split_verify_and_reject_tamper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; payload = b'abcdefghij'
            source.write_bytes(payload); target = root / 'parts'
            manifest = MODULE.split(source, target, part_size=4)
            self.assertEqual([p['bytes'] for p in manifest['parts']], [4, 4, 2])
            self.assertEqual(MODULE.verify(target)['sha256'], hashlib.sha256(payload).hexdigest())
            (target / 'part-0002').write_bytes(b'xxxx')
            with self.assertRaisesRegex(ValueError, 'part changed'):
                MODULE.verify(target)
            with self.assertRaisesRegex(ValueError, 'destination already exists'):
                MODULE.split(source, target, part_size=4)

    def test_rejects_oversized_parts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; source.write_bytes(b'x')
            with self.assertRaisesRegex(ValueError, 'part size'):
                MODULE.split(source, root / 'parts', MODULE.MAX_PART + 1)
