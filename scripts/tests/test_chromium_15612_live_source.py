import copy
import errno
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import chromium_15612_live_source as module
from chromium_15612_generated_cache import M156CacheError


def record(root, name):
    path = root / name
    info = path.lstat()
    result = {'kind': 'file', 'path': name, 'mode': stat.S_IMODE(info.st_mode)}
    if path.is_symlink():
        raw = os.fsencode(os.readlink(path))
        result.update(kind='symlink', targetLength=len(raw), targetSHA256=hashlib.sha256(raw).hexdigest())
    else:
        raw = path.read_bytes()
        result.update(sizeBytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    return result


def snapshot(entries):
    return {'schemaVersion': 1, 'recordType': 'chromium-source-snapshot',
            'targetChromiumVersion': module.cache.VERSION,
            'officialChromiumBase': {'commit': module.cache.COMMIT, 'tree': module.cache.TREE},
            'sourceFileCount': len(entries), 'deletedPathCount': 0, 'deletedPaths': [],
            'entries': sorted(entries, key=lambda item: item['path']), 'releaseReady': False}


class M156LiveSourceTests(unittest.TestCase):
    def hashes(self):
        directory = Path(module.__file__).parent
        return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in
                ('chromium_15612_live_source.py', 'chromium_15612_generated_cache.py',
                 'chromium_15612_postbuild.py', 'chromium_15612_receipt_projection.py')}

    def own_tree(self, root):
        (root / 'src').mkdir()
        (root / 'src' / 'one.cc').write_bytes(b'owned native source\n')
        (root / 'src' / 'two.cc').write_bytes(b'second independent leaf\n')
        return snapshot([record(root, 'src/one.cc'), record(root, 'src/two.cc')])

    def test_every_leaf_and_never_follow_symlink_targets(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-') as temp:
            root = Path(temp).resolve()
            full = self.own_tree(root)
            (root / 'empty').mkdir()
            (root / '.git').mkdir(); (root / '.git' / 'ignored').write_bytes(b'not source')
            (root / 'out').mkdir(); (root / 'out' / 'ignored').write_bytes(b'native build output')
            (root / 'src' / '.git').write_bytes(b'git worktree marker')
            (root / 'src' / 'out').mkdir(); (root / 'src' / 'out' / 'not-ignored').write_bytes(b'included')
            (root / 'external-link').symlink_to('/must-not-be-read/outside/source')
            (root / 'dir-link').symlink_to(root / 'src', target_is_directory=True)
            full = snapshot(full['entries'] + [record(root, name) for name in
                            ('src/out/not-ignored', 'external-link', 'dir-link')])
            observed = module.observe_tree(root, full)
            self.assertEqual(observed['sourceFileCount'], 5)
            self.assertTrue(observed['exactCoverageVerified'])
            self.assertTrue(observed['fdSafeFullObservationVerified'])
            self.assertEqual(observed['entriesSHA256'], module.postbuild.canonical_digest(full['entries']))

    def test_changed_same_size_old_inventory_mode_size_and_missing_rejected(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-content-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root)
            original = (root / 'src/one.cc').read_bytes()
            (root / 'src/one.cc').write_bytes(b'x' * len(original))
            with self.assertRaisesRegex(M156CacheError, 'bytes differ'):
                module.observe_tree(root, full)
            (root / 'src/one.cc').write_bytes(original)
            (root / 'src/one.cc').chmod(0o600)
            with self.assertRaises(M156CacheError): module.observe_tree(root, full)
            (root / 'src/one.cc').chmod(0o644)
            (root / 'src/one.cc').write_bytes(original + b'growth')
            with self.assertRaises(M156CacheError): module.observe_tree(root, full)
            (root / 'src/one.cc').unlink()
            with self.assertRaisesRegex(M156CacheError, 'Missing'):
                module.observe_tree(root, full)

    def test_extra_leaf_refused_before_its_content_is_read(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-extra-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root)
            (root / 'secret-extra').write_bytes(b'never read this content')
            real = module.os.open
            opened = []
            def observe(name, *args, **kwargs):
                opened.append(name)
                return real(name, *args, **kwargs)
            with patch.object(module.os, 'open', side_effect=observe):
                with self.assertRaisesRegex(M156CacheError, 'Extra'):
                    module.observe_tree(root, full)
            self.assertNotIn('secret-extra', opened)

    def test_fifo_hardlink_and_ambiguous_exclusion_links_rejected(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-types-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root)
            (root / 'src/one.cc').unlink(); os.mkfifo(root / 'src/one.cc')
            with self.assertRaisesRegex(M156CacheError, 'Special'):
                module.observe_tree(root, full)
            (root / 'src/one.cc').unlink(); os.link(root / 'src/two.cc', root / 'src/one.cc')
            with self.assertRaises(M156CacheError): module.observe_tree(root, full)
            (root / 'src/one.cc').unlink(); (root / 'src/one.cc').write_bytes(b'owned native source\n')
            for name in ('.git', 'out'):
                with self.subTest(name=name):
                    (root / name).symlink_to(root / 'src')
                    with self.assertRaisesRegex(M156CacheError, 'Ambiguous'):
                        module.observe_tree(root, full)
                    (root / name).unlink()

    def test_leaf_replaced_between_stat_and_open(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-leaf-race-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root); real = module.os.open
            def replace(name, flags, *args, **kwargs):
                if name == 'one.cc':
                    owned = root / 'src/one.cc'
                    owned.rename(root / 'src/held')
                    owned.symlink_to(root / 'src/two.cc')
                return real(name, flags, *args, **kwargs)
            with patch.object(module.os, 'open', side_effect=replace):
                with self.assertRaises((OSError, M156CacheError)): module.observe_tree(root, full)

    def test_file_growth_during_read_bounded_and_rejected(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-read-race-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root); real = module.os.read
            changed = False; requested = []
            def grow(descriptor, count):
                nonlocal changed
                requested.append(count)
                if not changed:
                    changed = True
                    with (root / 'src/one.cc').open('ab') as stream: stream.write(b'grow' * 10000)
                return real(descriptor, count)
            with patch.object(module.os, 'read', side_effect=grow):
                with self.assertRaisesRegex(M156CacheError, 'changed during read'):
                    module.observe_tree(root, full)
            self.assertLessEqual(sum(requested), len(b'owned native source\n') + 1)

    def test_symlink_target_changed_during_read(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-link-race-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root)
            (root / 'link').symlink_to('src/one.cc')
            full = snapshot(full['entries'] + [record(root, 'link')]); real = module.os.readlink
            def replace(name, *args, **kwargs):
                value = real(name, *args, **kwargs)
                if name == 'link':
                    (root / 'link').unlink(); (root / 'link').symlink_to('src/two.cc')
                return value
            with patch.object(module.os, 'readlink', side_effect=replace):
                with self.assertRaisesRegex(M156CacheError, 'symlink changed'):
                    module.observe_tree(root, full)

    def test_directory_replaced_before_open(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-directory-race-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root); real = module.os.open
            def replace(name, flags, *args, **kwargs):
                if name == 'src':
                    (root / 'src').rename(root / 'held')
                    (root / 'src').symlink_to(root / 'held', target_is_directory=True)
                return real(name, flags, *args, **kwargs)
            with patch.object(module.os, 'open', side_effect=replace):
                with self.assertRaises((M156CacheError, OSError)): module.observe_tree(root, full)

    def test_ancestor_and_root_replaced_during_held_traversal(self):
        for replace_ancestor in (False, True):
            with self.subTest(ancestor=replace_ancestor), tempfile.TemporaryDirectory(
                    prefix='neantik-full-observer-ancestor-race-') as temp:
                parent = Path(temp).resolve() / 'anchor'; parent.mkdir()
                root = parent / 'source'; root.mkdir(); full = self.own_tree(root)
                real = module.os.read; changed = False
                def replace(descriptor, count):
                    nonlocal changed
                    block = real(descriptor, count)
                    if not changed:
                        changed = True
                        path = parent if replace_ancestor else root
                        moved = path.with_name('held')
                        path.rename(moved); path.mkdir()
                    return block
                with patch.object(module.os, 'read', side_effect=replace):
                    # Root rename changes its ctime and can be refused by the
                    # directory guard before the retained ancestor guard runs.
                    with self.assertRaisesRegex(M156CacheError, 'ancestor replaced|directory changed'):
                        module.observe_tree(root, full)

    def test_directory_mutation_and_leaf_to_empty_directory_rejected(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-coverage-race-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root); real = module.os.read
            changed = False
            def mutate(descriptor, count):
                nonlocal changed
                block = real(descriptor, count)
                if not changed:
                    changed = True; (root / 'src/added-after-listing').write_bytes(b'new')
                return block
            with patch.object(module.os, 'read', side_effect=mutate):
                with self.assertRaisesRegex(M156CacheError, 'directory changed'):
                    module.observe_tree(root, full)
            (root / 'src/added-after-listing').unlink()
            (root / 'src/one.cc').unlink(); (root / 'src/one.cc').mkdir()
            with self.assertRaisesRegex(M156CacheError, 'leaf changed to directory'):
                module.observe_tree(root, full)

    def test_unsafe_inventory_depth_and_root_links_refused(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-bounds-') as temp:
            root = Path(temp).resolve(); full = self.own_tree(root)
            bad = copy.deepcopy(full); bad['entries'][0]['path'] = '../outside'
            with self.assertRaises(M156CacheError): module.observe_tree(root, bad)
            link = root / 'source-link'; link.symlink_to(root / 'src')
            with self.assertRaises(OSError):
                with module.anchored_root(link): pass
            with patch.object(module, 'MAX_DEPTH', 0):
                with self.assertRaises(M156CacheError): module.observe_tree(root, full)
            link.unlink()
            with patch.object(module, 'MAX_DIRECTORIES', 1):
                with self.assertRaisesRegex(M156CacheError, 'directory budget'):
                    module.observe_tree(root, full)

    def test_running_gate_before_snapshot_or_source_and_dependency_pins(self):
        artifacts = (Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major')
        name = 'm156-native-build-attempt-4-state.json'
        if not (artifacts / name).is_file(): self.skipTest('Owned running-state fixture not present')
        raw = (artifacts / name).read_bytes()
        if json.loads(raw).get('status') != 'single-native-build-running':
            self.skipTest('Build no longer running')
        with (patch.object(module.postbuild, 'bound_document', wraps=module.postbuild.bound_document) as read,
              patch.object(module, 'observe_tree') as observe):
            with self.assertRaisesRegex(M156CacheError, 'successful terminal'):
                module.prepare(artifacts=artifacts, source=Path('/must-not-read-source'),
                               terminal_name=name, terminal_sha256=hashlib.sha256(raw).hexdigest(),
                               final_name='must-not-read', final_sha256='a'*64,
                               compact_name='must-not-read', compact_sha256='a'*64, tool_hashes=self.hashes())
            self.assertEqual(read.call_count, 1); observe.assert_not_called()
        hashes = self.hashes(); module.require_tools(hashes)
        for name in hashes:
            with self.subTest(name=name), self.assertRaises(M156CacheError):
                module.require_tools({**hashes, name: 'b'*64})

    def test_bounded_readonly_git_plumbing_on_owned_repository(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-git-') as temp:
            root = Path(temp).resolve()
            subprocess.run(['/usr/bin/git', 'init', '-q', str(root)], check=True)
            # No commit, hooks, remote, credentials or real browser checkout.
            (root / 'owned.txt').write_text('owned')
            subprocess.run(['/usr/bin/git', '-C', str(root), 'add', 'owned.txt'], check=True)
            (root / 'owned.txt').unlink()
            self.assertEqual(module.git_output(root, ['ls-files', '--deleted', '-z'], 128), b'owned.txt\0')
            with self.assertRaisesRegex(M156CacheError, 'output exceeds'):
                module.git_output(root, ['ls-files', '--deleted', '-z'], 2)

    def test_cli_errors_redacted_and_no_output_created(self):
        with tempfile.TemporaryDirectory(prefix='neantik-full-observer-cli-') as temp:
            root = Path(temp).resolve(); output = root / 'must-not-exist.json'
            arguments = [sys.executable, '-S', '-B', module.__file__, '--artifacts', str(root / 'private'),
                         '--source', str(root / 'private-source'), '--terminal-name', 'state.json',
                         '--terminal-sha256', 'a'*64, '--final-name', 'full.json', '--final-sha256', 'a'*64,
                         '--compact-name', 'compact.json', '--compact-sha256', 'a'*64,
                         '--tool-hashes', json.dumps(self.hashes()), '--output', str(output)]
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertEqual(result.stderr, 'M156 full source observation refused; no qualification produced.\n')
            self.assertNotIn(temp, result.stderr); self.assertFalse(output.exists())

    def test_immutable_writer_exact_serialization_and_preserved_final(self):
        with tempfile.TemporaryDirectory(prefix='neantik-observer-writer-') as temp:
            root = Path(temp).resolve(); value = {'scope': 'source-only', 'text': 'é', 'ready': False}
            expected = (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()
            digest = module.write_observation_document(root, 'receipt.json', value)
            self.assertEqual((root / 'receipt.json').read_bytes(), expected)
            self.assertEqual(digest, hashlib.sha256(expected).hexdigest())
            self.assertEqual(stat.S_IMODE((root / 'receipt.json').stat().st_mode), 0o600)
            self.assertEqual((root / 'receipt.json').stat().st_nlink, 1)
            with self.assertRaises(FileExistsError):
                module.write_observation_document(root, 'receipt.json', {'overwrite': True})
            self.assertEqual((root / 'receipt.json').read_bytes(), expected)
            self.assertEqual([p.name for p in root.iterdir()], ['receipt.json'])

    def test_writer_temp_replacement_before_link_refused_without_deleting_foreign_inode(self):
        with tempfile.TemporaryDirectory(prefix='neantik-observer-writer-temp-race-') as temp:
            root = Path(temp).resolve(); real = module.os.link; substituted = []
            def replace(source, destination, *args, **kwargs):
                path = root / source
                path.rename(root / 'retained-written')
                path.write_bytes(b'{"foreign":true}')
                substituted.append(path)
                return real(source, destination, *args, **kwargs)
            with patch.object(module.os, 'link', side_effect=replace):
                with self.assertRaisesRegex(M156CacheError, 'publication differs'):
                    module.write_observation_document(root, 'receipt.json', {'scope': 'source-only'})
            self.assertEqual(substituted[0].read_bytes(), b'{"foreign":true}')
            # It is preserved for diagnosis, never returned as verified bytes.
            self.assertEqual((root / 'receipt.json').read_bytes(), b'{"foreign":true}')

    def test_writer_final_replacement_after_link_refused(self):
        with tempfile.TemporaryDirectory(prefix='neantik-observer-writer-final-race-') as temp:
            root = Path(temp).resolve(); real = module.os.link
            def replace(source, destination, *args, **kwargs):
                real(source, destination, *args, **kwargs)
                (root / destination).unlink(); (root / destination).write_bytes(b'foreign final')
            with patch.object(module.os, 'link', side_effect=replace):
                with self.assertRaisesRegex(M156CacheError, 'publication differs'):
                    module.write_observation_document(root, 'receipt.json', {'scope': 'source-only'})
            self.assertEqual((root / 'receipt.json').read_bytes(), b'foreign final')
            self.assertFalse(any('.new-' in p.name for p in root.iterdir()))

    def test_writer_failure_before_publication_cleans_only_owned_temp(self):
        with tempfile.TemporaryDirectory(prefix='neantik-observer-writer-fault-') as temp:
            root = Path(temp).resolve(); real = module.os.fsync; faulted = False
            def fault(descriptor):
                nonlocal faulted
                if not faulted:
                    faulted = True
                    raise OSError(errno.ENOSPC, 'Owned synthetic disk full')
                return real(descriptor)
            with patch.object(module.os, 'fsync', side_effect=fault):
                with self.assertRaises(OSError):
                    module.write_observation_document(root, 'receipt.json', {'scope': 'source-only'})
            self.assertEqual(list(root.iterdir()), [])


if __name__ == '__main__': unittest.main()
