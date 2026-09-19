import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gclient_input_bundle import load_recipe
from gclient_source_evidence import EvidenceError


class InputBundleTests(unittest.TestCase):
    def test_exact_bytes_and_mutation_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            data = b'{"reviewed":true}'
            (root / 'recipe.json').write_bytes(data)
            ref = {'path': 'recipe.json', 'sha256': hashlib.sha256(data).hexdigest()}
            self.assertEqual(load_recipe(root, ref), {'reviewed': True})
            (root / 'recipe.json').write_bytes(b'{"reviewed":false}')
            with self.assertRaises(EvidenceError):
                load_recipe(root, ref)

    def test_duplicate_keys_unsafe_paths_and_links_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            data = b'{"x":1,"x":2}'
            (root / 'recipe.json').write_bytes(data)
            sha = hashlib.sha256(data).hexdigest()
            (root / 'link').symlink_to('recipe.json')
            for name in ['recipe.json', 'link', '../recipe.json', '/recipe.json']:
                with self.subTest(name=name), self.assertRaises(EvidenceError):
                    load_recipe(root, {'path': name, 'sha256': sha})


if __name__ == '__main__':
    unittest.main()
