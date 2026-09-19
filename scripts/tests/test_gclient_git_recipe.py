import copy
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gclient_git_recipe import verify_git_recipe
from gclient_source_evidence import EvidenceError


class GitRecipeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'src'
        self.root.mkdir()
        self.init(self.root, '.gitignore', 'v8/\n')
        dep = self.root / 'v8'
        dep.mkdir()
        self.init(dep, 'source.txt', 'fixture\n')
        empty = hashlib.sha256(b'').hexdigest()
        self.recipe = {'schemaVersion': 1, 'scope': 'gclient-git-only',
            'root': {'commit': self.git(self.root, 'rev-parse', 'HEAD'),
                     'tree': self.git(self.root, 'rev-parse', 'HEAD^{tree}'),
                     'trackedPatchSHA256': empty, 'untrackedFiles': {}, 'untrackedLinks': {}},
            'dependencies': {'v8': {'commit': self.git(dep, 'rev-parse', 'HEAD'),
                'trackedPatchSHA256': empty, 'untrackedFiles': {}, 'untrackedLinks': {}}}}
        pin = self.recipe['dependencies']['v8']['commit']
        (self.root.parent / '.gclient_entries').write_text("entries = {'src/v8': 'https://example.invalid/v8.git@" + pin + "'}")

    def git(self, root, *args):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def init(self, root, name, content):
        self.git(root, 'init')
        (root / name).write_text(content)
        self.git(root, 'add', name)
        self.git(root, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture')

    def test_composite_success_and_dependency_mutation(self):
        result = verify_git_recipe(self.root, self.recipe)
        self.assertEqual(result['scope'], 'gclient-git-only')
        (self.root / 'v8/source.txt').write_text('mutated')
        with self.assertRaises(EvidenceError):
            verify_git_recipe(self.root, self.recipe)

    def test_missing_dependency_and_wrong_scope_fail(self):
        for key, value in [('dependencies', {}), ('scope', 'release-ready'), ('schemaVersion', True)]:
            changed = copy.deepcopy(self.recipe)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(EvidenceError):
                verify_git_recipe(self.root, changed)

    def test_unlisted_root_and_dependency_extras_fail(self):
        for relative in ['extra', 'v8/extra']:
            path = self.root / relative
            path.write_text('unreviewed')
            with self.subTest(relative=relative), self.assertRaises(EvidenceError):
                verify_git_recipe(self.root, self.recipe)
            path.unlink()


if __name__ == '__main__':
    unittest.main()
