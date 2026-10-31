import copy
import hashlib
import json
import sys
import tempfile
import unittest
from unittest.mock import patch as mock_patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chromium_additive_source_delta as delta


class AdditiveSourceDeltaTests(unittest.TestCase):
    def fixture(self, root):
        folder = root / 'runtime/overlay'
        folder.mkdir(parents=True)
        patch = folder / 'one.patch'
        patch.write_text('--- a/components/a.cc\n+++ b/components/a.cc\n@@ -1 +1 @@\n-before\n+after\n')
        sha = lambda value: hashlib.sha256(value).hexdigest()
        manifest = {'schemaVersion': 1, 'patchFile': patch.name, 'patchSHA256': sha(patch.read_bytes()),
                    'files': [{'path': 'components/a.cc', 'preimageSHA256': sha(b'before\n'),
                               'postimageSHA256': sha(b'after\n')}]}
        path = folder / 'manifest.json'
        path.write_text(json.dumps(manifest))
        return path, manifest, {'runtime/overlay/manifest.json': sha(path.read_bytes())}

    def test_pinned_manifest_and_exact_delta(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); _, _, pins = self.fixture(root)
            expected = delta.load_inputs(root, pins)
            records = self.records(expected)
            delta.verify_projection(records, expected, {key: value['postimageSHA256'] for key, value in expected.items()})

    def records(self, expected):
        def record(name, digest):
            return {'kind': 'file', 'path': name, 'mode': 0o644, 'sizeBytes': 7, 'sha256': digest}
        return [{'path': name, 'before': record(name, value['preimageSHA256']),
                 'after': record(name, value['postimageSHA256'])} for name, value in sorted(expected.items())]

    def test_manifest_patch_path_and_hash_negatives(self):
        mutations = [
            lambda m: m.update(schemaVersion=True),
            lambda m: m.update(patchSHA256='0' * 64),
            lambda m: m.update(patchFile='../one.patch'),
            lambda m: m['files'][0].update(path='../a.cc'),
            lambda m: m['files'][0].update(path='components/other.cc'),
            lambda m: m['files'][0].update(preimageSHA256='invalid'),
            lambda m: m['files'][0].update(postimageSHA256=m['files'][0]['preimageSHA256']),
            lambda m: m['files'].append(copy.deepcopy(m['files'][0])),
            lambda m: m['files'][0].update(extra=True),
            lambda m: m.update(parentManifest='runtime/foreign.json', parentManifestSHA256='0' * 64),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutations.index(mutate)), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); path, manifest, pins = self.fixture(root)
                mutate(manifest); path.write_text(json.dumps(manifest))
                pins[next(iter(pins))] = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaises(ValueError): delta.load_inputs(root, pins)

    def test_external_manifest_or_changed_pinned_bytes_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); path, _, pins = self.fixture(root)
            path.write_text(path.read_text() + '\n')
            with self.assertRaises(ValueError): delta.load_inputs(root, pins)
            with self.assertRaises(ValueError): delta.load_inputs(root, {'../outside': '0' * 64})

    def test_exact_projection_negatives(self):
        expected = {'components/a.cc': {'preimageSHA256': 'a' * 64, 'postimageSHA256': 'b' * 64}}
        base = self.records(expected); post = {'components/a.cc': 'b' * 64}
        mutations = [lambda rows: rows.clear(), lambda rows: rows.append(copy.deepcopy(rows[0])),
                     lambda rows: rows[0].update(path='components/other.cc'),
                     lambda rows: rows[0].update(before=None), lambda rows: rows[0].update(after=None),
                     lambda rows: rows[0]['before'].update(sha256='0' * 64),
                     lambda rows: rows[0]['after'].update(sha256='0' * 64),
                     lambda rows: rows[0]['after'].update(mode=True),
                     lambda rows: rows[0]['after'].update(mode=0o755),
                     lambda rows: rows[0]['after'].update(sizeBytes=0),
                     lambda rows: rows[0]['after'].update(kind='symlink'),
                     lambda rows: rows[0]['after'].update(extra=True)]
        for mutate in mutations:
            rows = copy.deepcopy(base); mutate(rows)
            with self.subTest(mutation=mutations.index(mutate)), self.assertRaises(ValueError):
                delta.verify_projection(rows, expected, post)
        for invalid in [{}, {'components/a.cc': '0' * 64}, {**post, 'extra.cc': 'b' * 64}]:
            with self.assertRaises(ValueError): delta.verify_projection(base, expected, invalid)

    def test_swap_after_hash_cannot_change_authenticated_parse(self):
        # Swap the pathname after hashing the retained buffer. Both manifest
        # and patch parsing must continue to use those authenticated bytes.
        for swap_name in ('manifest.json', 'one.patch'):
            with self.subTest(swap=swap_name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); path, _, pins = self.fixture(root)
                target = path.parent / swap_name
                original = target.read_bytes()
                digest = delta.base.digest
                swapped = False

                def swap_after_digest(raw):
                    nonlocal swapped
                    result = digest(raw)
                    if raw == original and not swapped:
                        swapped = True
                        replacement = target.with_name(target.name + '.replacement')
                        replacement.write_bytes(b'{}' if swap_name.endswith('.json') else b'--- a/foreign.cc\n+++ b/foreign.cc\n')
                        replacement.replace(target)
                    return result

                with mock_patch.object(delta.base, 'digest', side_effect=swap_after_digest):
                    expected = delta.load_inputs(root, pins)
                self.assertTrue(swapped)
                self.assertEqual(set(expected), {'components/a.cc'})
                # A subsequent independent observation must reject the swap.
                with self.assertRaises(ValueError): delta.load_inputs(root, pins)


if __name__ == '__main__':
    unittest.main()
