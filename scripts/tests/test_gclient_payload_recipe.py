import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gclient_payload_recipe import verify_payload_recipe
from gclient_source_evidence import EvidenceError


class PayloadRecipeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        (self.base / 'pkg').mkdir()
        (self.base / 'pkg/file').write_bytes(b'reviewed')
        self.recipe = {'schemaVersion': 1, 'scope': 'gclient-payload-trees-only',
            'roots': ['pkg'], 'files': {'pkg/file': hashlib.sha256(b'reviewed').hexdigest()}, 'links': {}}

    def test_exact_inventory_and_content(self):
        verify_payload_recipe(self.base, self.recipe)
        (self.base / 'pkg/.hidden-extra').write_bytes(b'unexpected')
        with self.assertRaises(EvidenceError):
            verify_payload_recipe(self.base, self.recipe)
        (self.base / 'pkg/.hidden-extra').unlink()
        (self.base / 'pkg/file').write_bytes(b'modified')
        with self.assertRaises(EvidenceError):
            verify_payload_recipe(self.base, self.recipe)

    def test_links_require_verified_contained_destination(self):
        (self.base / 'pkg/link').symlink_to('file')
        self.recipe['links']['pkg/link'] = 'file'
        verify_payload_recipe(self.base, self.recipe)
        (self.base / 'pkg/link').unlink()
        (self.base / 'outside').write_bytes(b'reviewed')
        (self.base / 'pkg/link').symlink_to('../outside')
        self.recipe['links']['pkg/link'] = '../outside'
        with self.assertRaises(EvidenceError):
            verify_payload_recipe(self.base, self.recipe)

    def test_unsafe_overlapping_and_uncovered_paths(self):
        for roots in [['../pkg'], ['pkg', 'pkg'], ['pkg', 'pkg/nested']]:
            changed = copy.deepcopy(self.recipe)
            changed['roots'] = roots
            with self.subTest(roots=roots), self.assertRaises(EvidenceError):
                verify_payload_recipe(self.base, changed)
        self.recipe['files']['other/file'] = '0' * 64
        with self.assertRaises(EvidenceError):
            verify_payload_recipe(self.base, self.recipe)

    def test_absent_link_requires_explicit_exact_exception(self):
        (self.base / 'pkg/link').symlink_to('absent')
        self.recipe['links']['pkg/link'] = 'absent'
        with self.assertRaises(EvidenceError):
            verify_payload_recipe(self.base, self.recipe)
        self.recipe['missingLinkTargets'] = {'pkg/link': 'pkg/absent'}
        verify_payload_recipe(self.base, self.recipe)
        self.recipe['missingLinkTargets']['pkg/link'] = 'pkg/wrong'
        with self.assertRaises(EvidenceError):
            verify_payload_recipe(self.base, self.recipe)


if __name__ == '__main__':
    unittest.main()
