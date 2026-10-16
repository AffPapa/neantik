"""Metadata safety controls; none execute or qualify a browser."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import security_backport_source_delta as subject

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / subject.DIRECTORY / 'manifest.json'
PIN = hashlib.sha256(MANIFEST.read_bytes()).hexdigest()


class SecurityBackportSourceDeltaTests(unittest.TestCase):
    def fixture(self):
        expected = subject.load_inputs(ROOT, PIN)
        changes, postimages = [], {}
        for index, (path, item) in enumerate(sorted(expected.items())):
            def descriptor(sha):
                return {'kind': 'file', 'path': path, 'mode': 0o644,
                        'sizeBytes': 50, 'sha256': sha}
            # Synthetic projection only; real sizes/after hashes come from FD/build receipts.
            after_sha = hashlib.sha256(('synthetic-after-' + str(index)).encode()).hexdigest()
            before = None if item['change'] == 'add' else descriptor(item['beforeSHA256'])
            after = None if item['change'] == 'delete' else descriptor(after_sha)
            changes.append({'path': path, 'before': before, 'after': after})
            postimages[path] = None if after is None else after_sha
        return expected, changes, postimages

    def test_actual_pinned_patch_inputs_are_closed(self):
        expected = subject.load_inputs(ROOT, PIN)
        self.assertEqual(len(expected), 35)
        self.assertEqual(sum(v['change'] == 'add' for v in expected.values()), 6)
        self.assertEqual(sum(v['change'] == 'delete' for v in expected.values()), 2)
        self.assertTrue(any(path.startswith('v8/') for path in expected))

    def test_manifest_pin_cannot_be_replaced_by_a_self_claim(self):
        with self.assertRaises(ValueError):
            subject.load_inputs(ROOT, '0' * 64)
        with self.assertRaises(ValueError):
            subject.load_inputs(ROOT, None)

    def test_structurally_complete_projection_matches_bound_model(self):
        expected, changes, postimages = self.fixture()
        subject.verify_projection(changes, expected, postimages)

    def test_missing_35th_source_and_extra_source_are_refused(self):
        expected, changes, postimages = self.fixture()
        for broken in (changes[:-1], changes + [copy.deepcopy(changes[0])]):
            with self.subTest(length=len(broken)), self.assertRaisesRegex(ValueError, 'coverage'):
                subject.verify_projection(broken, expected, postimages)
        wrong_postimages = dict(postimages)
        wrong_postimages.pop(changes[-1]['path'])
        with self.assertRaisesRegex(ValueError, 'coverage'):
            subject.verify_projection(changes, expected, wrong_postimages)

    def test_altered_35th_postimage_is_refused(self):
        expected, changes, postimages = self.fixture()
        self.assertIsNotNone(changes[-1]['after'])
        changes[-1]['after']['sha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'postimage'):
            subject.verify_projection(changes, expected, postimages)

    def test_preimage_addition_deletion_and_modes_are_checked(self):
        for mutation in ('preimage', 'add-existed', 'delete-present', 'mode', 'bool-size'):
            expected, changes, postimages = self.fixture()
            if mutation == 'preimage':
                next(x for x in changes if x['before'])['before']['sha256'] = 'f' * 64
            elif mutation == 'add-existed':
                item = next(x for x in changes if x['before'] is None)
                item['before'] = copy.deepcopy(item['after'])
            elif mutation == 'delete-present':
                item = next(x for x in changes if x['after'] is None)
                item['after'] = copy.deepcopy(item['before'])
            elif mutation == 'mode':
                next(x for x in changes if x['after'])['after']['mode'] = 0o755
            else:
                next(x for x in changes if x['after'])['after']['sizeBytes'] = True
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                subject.verify_projection(changes, expected, postimages)

    def test_unrelated_duplicate_unsorted_and_traversal_paths_are_refused(self):
        for mutation in ('unrelated', 'duplicate', 'unsorted', 'traversal'):
            expected, changes, postimages = self.fixture()
            if mutation == 'unrelated': changes[-1]['path'] = 'unexpected.cc'
            elif mutation == 'duplicate': changes[-1]['path'] = changes[0]['path']
            elif mutation == 'unsorted': changes.reverse()
            else: changes[-1]['path'] = '../unexpected.cc'
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                subject.verify_projection(changes, expected, postimages)

    def test_patch_tamper_symlink_and_wrong_root_fail_closed(self):
        for mutation in ('patch-tamper', 'symlink', 'wrong-root', 'drop-fix'):
            with tempfile.TemporaryDirectory(prefix='neantik-own-security-inputs-') as directory:
                project = Path(directory)
                destination = project / subject.DIRECTORY
                destination.parent.mkdir(parents=True)
                shutil.copytree(ROOT / subject.DIRECTORY, destination)
                contract = project / 'runtime/chromium-15612-font-system-v1-source-contract.json'
                contract.write_bytes((ROOT / contract.relative_to(project)).read_bytes())
                manifest = json.loads((destination / 'manifest.json').read_text())
                patch = project / manifest['orderedPatches'][0]['path']
                expected_pin = PIN
                if mutation == 'patch-tamper': patch.write_bytes(patch.read_bytes() + b'\n')
                elif mutation == 'symlink':
                    own_saved = destination / 'own-patch.txt'
                    patch.rename(own_saved)
                    patch.symlink_to(own_saved.name)
                else:
                    if mutation == 'wrong-root': manifest['orderedPatches'][0]['applyRoot'] = 'v8'
                    else: manifest['orderedPatches'].pop()
                    raw = (json.dumps(manifest, indent=2) + '\n').encode()
                    (destination / 'manifest.json').write_bytes(raw)
                    expected_pin = hashlib.sha256(raw).hexdigest()
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    subject.load_inputs(project, expected_pin)


if __name__ == '__main__':
    unittest.main()
