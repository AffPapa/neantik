import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('recipient_privacy', ROOT / 'scripts/recipient-privacy.py')
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)

class RecipientPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-recipient-unit-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / 'project'; self.project.mkdir()
        self.source = self.root / 'recipient'; self.source.mkdir()
        self.before = self.project / 'before'; self.before.write_bytes(b'base')
        self.after = self.project / 'after'; self.after.write_bytes(b'patched')
        self.layer = {'files': [self.row('a.cc')], 'supplementalSources': [self.row('new.h', new=True)]}
        (self.source / 'a.cc').write_bytes(b'base')

    def binding(self, p):
        return {'file': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}

    def row(self, name, new=False):
        return {'source': name, 'preimage': self.binding(self.before), 'postimage': self.binding(self.after), **({'beforeAbsent': True} if new else {})}

    def test_partial_apply_resume_and_foreign_edit_refusal(self):
        replay.apply(self.project, self.source, self.layer)
        replay.apply(self.project, self.source, self.layer)
        self.assertEqual((self.source / 'new.h').read_bytes(), b'patched')
        (self.source / 'a.cc').write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError, 'differs'): replay.apply(self.project, self.source, self.layer)
        self.assertEqual((self.source / 'a.cc').read_bytes(), b'foreign')

    def test_collision_or_symlink_refuses_before_any_write(self):
        target = self.source / 'new.h'; target.write_bytes(b'foreign')
        with self.assertRaises(ValueError): replay.apply(self.project, self.source, self.layer)
        self.assertEqual((self.source / 'a.cc').read_bytes(), b'base')
        target.unlink(); target.symlink_to(self.after)
        with self.assertRaises(ValueError): replay.apply(self.project, self.source, self.layer)

    def test_byte_difference_is_explicit_and_never_follows_symlinks(self):
        target = self.source / 'object.o'; target.write_bytes(b'different debug path')
        with self.assertRaises(ValueError): replay.output_file(self.source, 'object.o', '0' * 64)
        self.assertEqual(replay.output_file(self.source, 'object.o', '0' * 64, allow_differences=True), target)
        target.unlink(); target.symlink_to(self.after)
        with self.assertRaises(ValueError): replay.output_file(self.source, 'object.o', '0' * 64, allow_differences=True)

    def test_default_is_inert_and_mutation_requires_confirmation(self):
        with patch.object(replay, 'verify_contract', return_value=({}, self.layer)), patch.object(replay, 'apply') as apply:
            self.assertEqual(replay.main(['--project-root', str(self.project)]), 0)
            with self.assertRaisesRegex(ValueError, 'confirm-disposable'):
                replay.main(['--project-root', str(self.project), '--source-root', str(self.source), '--action', 'apply'])
            apply.assert_not_called()

if __name__ == '__main__': unittest.main()
