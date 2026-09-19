import hashlib
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gclient_source_evidence as subject


class GclientEvidenceTests(unittest.TestCase):
    def test_untracked_missing_file_and_wrong_root_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(['git', 'init', str(root)], check=True, capture_output=True)
            with self.assertRaises(subject.EvidenceError):
                subject.verify_nonignored_untracked(root, {'missing': '0' * 64}, {})
            (root / 'nested').mkdir()
            with self.assertRaises(subject.EvidenceError):
                subject.verify_nonignored_untracked(root / 'nested', {}, {})

    def test_untracked_link_target_type_and_payload_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(['git', 'init', str(root)], check=True, capture_output=True)
            (root / 'payload').write_bytes(b'expected')
            subprocess.run(['git', '-C', str(root), 'add', 'payload'], check=True)
            (root / 'link').symlink_to('payload')
            expected = {'link': {'target': 'payload', 'sha256': hashlib.sha256(b'expected').hexdigest()}}
            for record in [{'target': 'wrong', 'sha256': '0' * 64},
                           {'target': 'payload', 'sha256': '0' * 64},
                           {'target': 'payload'},
                           {'target': 'payload', 'sha256': '0' * 64, 'extra': True}]:
                with self.subTest(record=record), self.assertRaises(subject.EvidenceError):
                    subject.verify_nonignored_untracked(root, {}, {'link': record})
            (root / 'link').unlink()
            (root / 'link').write_bytes(b'expected')
            with self.assertRaises(subject.EvidenceError):
                subject.verify_nonignored_untracked(root, {}, expected)

    def test_untracked_exact_inventory_hash_and_ignored_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(['git', 'init', str(root)], check=True, capture_output=True)
            self.assertEqual(subject.verify_nonignored_untracked(root, {}, {}), {})
            (root / '.gitignore').write_text('ignored\n')
            subprocess.run(['git', '-C', str(root), 'add', '.gitignore'], check=True)
            (root / 'ignored').write_bytes(b'outside this verifier scope')
            (root / 'extra').write_bytes(b'reviewed')
            expected = {'extra': hashlib.sha256(b'reviewed').hexdigest()}
            self.assertEqual(subject.verify_nonignored_untracked(root, expected, {}), expected)
            with self.assertRaises(subject.EvidenceError):
                subject.verify_nonignored_untracked(root, {}, {})
            (root / 'extra').write_bytes(b'mutated')
            with self.assertRaises(subject.EvidenceError):
                subject.verify_nonignored_untracked(root, expected, {})

    def test_untracked_reviewed_link_and_escape_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / 'repo'
            root.mkdir()
            subprocess.run(['git', 'init', str(root)], check=True, capture_output=True)
            (root / 'binary').write_bytes(b'payload')
            subprocess.run(['git', '-C', str(root), 'add', 'binary'], check=True)
            (root / 'link').symlink_to('binary')
            digest = hashlib.sha256(b'payload').hexdigest()
            links = {'link': {'target': 'binary', 'sha256': digest}}
            self.assertEqual(subject.verify_nonignored_untracked(root, {}, links), links)
            (root / 'link').unlink()
            (root.parent / 'outside').write_bytes(b'payload')
            (root / 'link').symlink_to('../outside')
            with self.assertRaises(subject.EvidenceError):
                subject.verify_nonignored_untracked(root, {}, {'link': {'target': '../outside', 'sha256': digest}})

    def test_git_identity_rejects_wrong_commit_tree_and_subdirectory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            def git(*args):
                return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True, text=True).stdout.strip()
            git('init')
            (root / 'DEPS').write_text('fixture')
            git('add', 'DEPS')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture')
            commit, tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
            empty_hash = hashlib.sha256(b'').hexdigest()
            self.assertEqual(subject.verify_tracked_patch(root, empty_hash), empty_hash)
            verified = subject.verify_dependency_checkouts(root.parent, {root.name: commit}, {})
            self.assertEqual(verified[root.name]['commit'], commit)
            with self.assertRaises(subject.EvidenceError):
                subject.verify_dependency_checkouts(root.parent, {root.name: '0' * 40}, {})
            (root / 'DEPS').write_text('unexpected edit')
            with self.assertRaises(subject.EvidenceError):
                subject.verify_dependency_checkouts(root.parent, {root.name: commit}, {})
            with self.assertRaises(subject.EvidenceError):
                subject.verify_tracked_patch(root, empty_hash)
            git('add', 'DEPS')
            with self.assertRaises(subject.EvidenceError):
                subject.verify_tracked_patch(root, empty_hash)
            self.assertEqual(subject.verify_git_identity(root, commit=commit, tree=tree), {'commit': commit, 'tree': tree})
            with self.assertRaises(subject.EvidenceError):
                subject.verify_git_identity(root, commit='0' * 40, tree=tree)
            with self.assertRaises(subject.EvidenceError):
                subject.verify_git_identity(root, commit=commit, tree='0' * 40)
            (root / 'nested').mkdir()
            with self.assertRaises(subject.EvidenceError):
                subject.verify_git_identity(root / 'nested', commit=commit, tree=tree)

    def test_inventory_is_data_not_code(self):
        revision = 'a' * 40
        self.assertEqual(subject.parse_git_dependencies("entries = {'src/openscreen': 'https://example.test/openscreen@" + revision + "'}"), {'openscreen': revision})
        self.assertEqual(subject.parse_git_dependencies("entries = {'src/v8': 'https://example.test/v8.git@" + revision + "'}"), {'v8': revision})
        for text in ["entries = dict()", "import os\nentries = {}", "entries = {'src/../escape': 'x.git@" + revision + "'}", "entries = {'src/v8': 'x.git@main'}"]:
            with self.subTest(text=text), self.assertRaises(subject.EvidenceError):
                subject.parse_git_dependencies(text)

    def test_exact_hash_and_mutation_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'DEPS').write_bytes(b'pinned')
            expected = {'DEPS': hashlib.sha256(b'pinned').hexdigest()}
            self.assertEqual(subject.verify_files(root, expected), expected)
            (root / 'DEPS').write_bytes(b'changed')
            with self.assertRaises(subject.EvidenceError):
                subject.verify_files(root, expected)

    def test_missing_invalid_and_escape_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ['../secret', '/secret', 'a/../b', './DEPS', 'missing', 'a\\b']:
                with self.subTest(name=name), self.assertRaises(subject.EvidenceError):
                    subject.verify_files(Path(directory), {name: '0' * 64})
            with self.assertRaises(subject.EvidenceError):
                subject.verify_files(Path(directory), {})

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'real').write_bytes(b'x')
            (root / 'link').symlink_to(root / 'real')
            with self.assertRaises(subject.EvidenceError):
                subject.verify_files(root, {'link': hashlib.sha256(b'x').hexdigest()})

if __name__ == '__main__':
    unittest.main()
