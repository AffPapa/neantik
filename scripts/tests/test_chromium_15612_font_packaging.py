"""Owned byte fixtures for current packaging custody; no source execution."""
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import unittest
from chromium_15612_font_packaging import verify_entries, manifest


class CurrentFontPackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.path = self.root / 'tools/licenses/licenses.py'
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(b'owned bytes; never executed\n')
        self.entry = {'kind': 'file', 'path': 'tools/licenses/licenses.py',
                      'sizeBytes': self.path.stat().st_size, 'mode': stat.S_IMODE(self.path.stat().st_mode),
                      'sha256': hashlib.sha256(self.path.read_bytes()).hexdigest()}

    def test_changed_size_hash_mode_and_missing_file_refused(self):
        verify_entries(self.root, [self.entry], [])
        original = self.path.read_bytes()
        self.path.write_bytes(original.replace(b'owned', b'wrong'))
        with self.assertRaisesRegex(ValueError, 'changed'):
            verify_entries(self.root, [self.entry], [])
        self.path.write_bytes(original + b'extra')
        with self.assertRaises(ValueError):
            verify_entries(self.root, [self.entry], [])
        self.path.write_bytes(original)
        self.path.chmod(0o700)
        with self.assertRaisesRegex(ValueError, 'changed'):
            verify_entries(self.root, [self.entry], [])
        self.path.unlink()
        with self.assertRaises(OSError):
            verify_entries(self.root, [self.entry], [])

    def test_links_and_traversal_refused(self):
        self.path.unlink()
        outside = self.root / 'outside'
        outside.write_bytes(b'owned bytes; never executed\n')
        self.path.symlink_to(outside)
        with self.assertRaises(OSError):
            verify_entries(self.root, [self.entry], [])
        self.path.unlink()
        os.link(outside, self.path)
        with self.assertRaises(ValueError):
            verify_entries(self.root, [self.entry], [])
        with self.assertRaises(ValueError):
            verify_entries(self.root, [{**self.entry, 'path': '../outside'}], [])

    def test_only_exact_known_copy_group_is_allowed(self):
        alias = self.root / 'out/NeAntikM156Qualified20261009/LICENSE'
        alias.parent.mkdir(parents=True)
        os.link(self.path, alias)
        group = {k: v for k, v in self.entry.items() if k != 'kind'}
        group.update(links=2, outputAliases=['out/NeAntikM156Qualified20261009/LICENSE'])
        verify_entries(self.root, [self.entry], [group])
        rogue = self.root / 'unnamed-alias'
        os.link(self.path, rogue)
        with self.assertRaisesRegex(ValueError, 'COPY'):
            verify_entries(self.root, [self.entry], [group])
        rogue.unlink()
        alias.unlink()
        alias.write_bytes(self.path.read_bytes())
        with self.assertRaisesRegex(ValueError, 'COPY'):
            verify_entries(self.root, [self.entry], [group])

    def test_project_manifest_is_independently_pinned_and_bounded(self):
        document = manifest(Path(__file__).resolve().parents[2])
        self.assertEqual(len(document['entries']), 9552)
        self.assertEqual(len(document['knownNativeCopyGroups']), 1)
        self.assertFalse(document['releaseReady'])
        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder)
            (project / 'runtime').mkdir()
            (project / 'runtime/chromium-15612-font-system-v1-packaging-inputs.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'bound file changed'):
                manifest(project)
