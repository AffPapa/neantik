import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('reconstruction', Path(__file__).resolve().parents[1] / 'chromium_154_reconstruction.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class ReconstructionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paths = {}
        self.write('root-tracked-delta.tsv', 'M\tinput.cc\nD\tpruned.cc\n', raw=True)
        self.write('pruning-present.list', 'pruned.cc\n', raw=True)
        self.write('dependency-tracked-deltas.json', {'dependencies': []})
        self.write('dependency-head-audit.json', {'entries': []})
        self.write('esbuild-npm-package-verification.json', {'files': []})
        for name in ('root-domain-replay.json', 'dependency-domain-replay.json'):
            self.write(name, {'files': []})
        self.report = 'sparse-replay-030tqb9v/report.json'
        self.write(self.report, {'files': [{'path': 'input.cc', 'expected': 'a'*64, 'actual': 'a'*64, 'matches': True}]})
        self.rows = [
            {'owner': 'root', 'status': 'M', 'path': 'input.cc', 'decision': {'method': 'replayed-postimage', 'report': self.report, 'postimageSHA256': 'a'*64}},
            {'owner': 'root', 'status': 'D', 'path': 'pruned.cc', 'decision': {'method': 'upstream-pruning'}},
        ]
        self.write('tracked-delta-attribution.json', {'changes': self.rows})

    def write(self, name, value, raw=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value if raw else json.dumps(value))
        self.paths[name] = path

    def manifest(self):
        return {'schemaVersion': 1, 'qualificationMethod': 'current-input-reconstruction-v1', 'releaseReady': False,
                'evidence': [{'path': name, 'sha256': M.sha256(path)} for name, path in self.paths.items()]}

    def test_exact_attribution_passes_without_claiming_release(self):
        result = M.verify_tracked_attribution(M.bound_evidence(self.root, self.manifest()))
        self.assertEqual(result['trackedChangesVerified'], 2)
        self.assertIs(result['releaseReady'], False)

    def test_omitted_and_duplicate_changes_fail(self):
        for rows in (self.rows[:1], self.rows + self.rows[:1]):
            self.write('tracked-delta-attribution.json', {'changes': rows})
            with self.assertRaises(M.ReconstructionError):
                M.verify_tracked_attribution(self.paths)

    def test_rehashed_but_false_replay_claim_fails(self):
        self.write(self.report, {'files': [{'path': 'input.cc', 'expected': 'b'*64, 'actual': 'a'*64, 'matches': True}]})
        with self.assertRaises(M.ReconstructionError):
            M.verify_tracked_attribution(M.bound_evidence(self.root, self.manifest()))

    def test_arbitrary_deletion_cannot_use_cache_exception(self):
        rows = copy.deepcopy(self.rows)
        rows[1]['decision'] = {'method': 'removed-derived-python-cache'}
        self.write('tracked-delta-attribution.json', {'changes': rows})
        with self.assertRaises(M.ReconstructionError):
            M.verify_tracked_attribution(self.paths)

    def test_changed_bytes_and_unsafe_paths_fail(self):
        manifest = self.manifest()
        self.paths['root-tracked-delta.tsv'].write_text('changed')
        with self.assertRaises(M.ReconstructionError):
            M.bound_evidence(self.root, manifest)
        for name in ('../escape', '/absolute', 'dir\\escape'):
            bad = self.manifest()
            bad['evidence'][0]['path'] = name
            with self.assertRaises(M.ReconstructionError):
                M.bound_evidence(self.root, bad)

    def test_evidence_symlink_and_duplicate_fail(self):
        manifest = self.manifest()
        manifest['evidence'].append(manifest['evidence'][0])
        with self.assertRaises(M.ReconstructionError):
            M.bound_evidence(self.root, manifest)

        link = self.root / 'link'
        link.symlink_to(self.paths['root-tracked-delta.tsv'])
        manifest = self.manifest()
        manifest['evidence'] = [{'path': 'link', 'sha256': M.sha256(link)}]
        with self.assertRaises(M.ReconstructionError):
            M.bound_evidence(self.root, manifest)

    def test_replay_review_binds_actual_order_and_offsets(self):
        self.write('dependency-head-audit.json', {'entries': [
            {'path': f'dep/{i}', 'actual': f'{i:040x}', 'expected': f'{i:040x}', 'status': 'match'} for i in range(149)]})
        patches = [{'name': f'{i}.patch', 'sha256': f'{i:064x}', 'offsetMessages': []} for i in range(205)]
        patches[130]['offsetMessages'] = ['Hunk #1 succeeded at 20 (offset 2 lines).']
        report = {'patches': patches, 'files': [
            {'path': f'file/{i}', 'expected': f'{i:064x}', 'actual': f'{i:064x}', 'matches': True} for i in range(815)]}
        previous = 'sparse-replay-9at859i5/report.json'
        review = 'sparse-replay-9at859i5/offset-review.json'
        binding = 'sparse-replay-030tqb9v/review-binding.json'
        self.write(self.report, report)
        self.write('ordered-patch-inputs.json', {'patches': [{'name': x['name'], 'sha256': x['sha256']} for x in patches]})
        self.write(previous, report)
        self.write(review, {'reportSHA256': M.sha256(self.paths[previous]),
                           'decision': 'exact-context line relocations accepted for sparse replay only'})
        self.write(binding, {'reportSHA256': M.sha256(self.paths[self.report]),
                             'previousOffsetReviewSHA256': M.sha256(self.paths[review])})
        experiment = {'ownedPatchApplyCheck': {'groups': [
            {'patchFile': x['name'], 'sha256': x['sha256']} for x in patches[129:202]]}}
        self.assertEqual(M.verify_replay_bindings(self.paths, experiment)['ownedPatchOrderVerified'], 73)
        for index in (0, 204):
            altered = copy.deepcopy(report)
            altered['patches'][index]['sha256'] = 'f' * 64
            self.write(self.report, altered)
            with self.assertRaisesRegex(M.ReconstructionError, 'Full patch sequence'):
                M.verify_replay_bindings(self.paths, experiment)
        self.write(self.report, report)
        bad = copy.deepcopy(experiment)
        bad['ownedPatchApplyCheck']['groups'].reverse()
        with self.assertRaises(M.ReconstructionError):
            M.verify_replay_bindings(self.paths, bad)
        # Even with a freshly rebound current report, previously unreviewed
        # offsets must not inherit approval from a boolean flag.
        report['patches'][130]['offsetMessages'] = ['Hunk #1 succeeded at 25 (offset 7 lines).']
        self.write(self.report, report)
        self.write(binding, {'reportSHA256': M.sha256(self.paths[self.report]),
                             'previousOffsetReviewSHA256': M.sha256(self.paths[review]),
                             'sameReviewedOffsetHunks': True})
        with self.assertRaises(M.ReconstructionError):
            M.verify_replay_bindings(self.paths, experiment)

    def test_missing_dependency_owner_is_rejected(self):
        self.write('dependency-head-audit.json', {'entries': [{'path': 'src/dep', 'expected': 'a'*40}]})
        with self.assertRaisesRegex(M.ReconstructionError, 'tracked inventory'):
            M.verify_tracked_attribution(self.paths)

    def test_archive_boolean_cannot_replace_locked_digest(self):
        self.write('extracted-toolchain-verification.json', {'complete': True, 'tools': [
            {'tool': name, 'archiveDigestMatches': True, 'archiveDigestAlgorithm': 'sha512',
             'archiveDigest': 'f'*128, 'files': []} for name in ('llvm', 'nodejs', 'rust')]})
        with self.assertRaisesRegex(M.ReconstructionError, 'pinned downloads input'):
            M.verify_tools_and_untracked(self.paths)

    def test_live_symlink_targets_cannot_change_bytes_undetected(self):
        source = self.root / 'src'
        prefix = source / 'third_party/devtools-frontend/src/node_modules'
        package = self.root / 'external-package'
        (package / 'bin').mkdir(parents=True)
        (package / 'bin/esbuild').write_bytes(b'js entry')
        binary = self.root / 'native-esbuild'
        binary.write_bytes(b'native tool')
        for relative, target in (('esbuild', package), ('.bin/esbuild', package / 'bin/esbuild'),
                                 ('@esbuild/darwin-arm64/bin/esbuild', binary)):
            link = prefix / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
        self.write('esbuild-observed-inputs.json', {
            'binarySHA256': M.sha256(binary),
            'packageFiles': [{'path': 'bin/esbuild', 'sha256': M.sha256(package / 'bin/esbuild')}],
        })
        M.verify_live_external_inputs(source, self.paths)
        binary.write_bytes(b'replaced tool')
        with self.assertRaisesRegex(M.ReconstructionError, 'executable changed'):
            M.verify_live_external_inputs(source, self.paths)
        binary.write_bytes(b'native tool')
        (package / 'extra.js').write_bytes(b'undeclared module')
        with self.assertRaisesRegex(M.ReconstructionError, 'package bytes changed'):
            M.verify_live_external_inputs(source, self.paths)


if __name__ == '__main__':
    unittest.main()
