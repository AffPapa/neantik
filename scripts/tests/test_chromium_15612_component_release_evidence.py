"""Actual frozen source proof plus deliberately mixed/failed model controls.

These tests never launch Chromium and are not release qualification.
"""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import chromium_15612_component_release_evidence as subject
import chromium_15612_security_release_evidence as parent
import chromium_15612_variant as variant
import chromium_15612_packaged_evidence as packaged
from runtime_build_path import verify_build_args


def document(prefix, suffix):
    return json.loads((ROOT / 'runtime' / (prefix + '-' + suffix + '.json')).read_text())


class ComponentSourceEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ancestor = parent.verify_contract(ROOT)
        cls.proof = document(subject.PREFIX, 'source-proof')
        cls.candidate = document(subject.PREFIX, 'port-candidate')
        cls.lock = json.loads((ROOT / 'runtime' / ('fingerprint-' + subject.PREFIX + '.lock.json')).read_text())

    def test_actual_family_and_closed_variant(self):
        contract, snapshot, proof = subject.verify_contract(ROOT)
        self.assertEqual(contract['schemaVersion'], 5)
        self.assertEqual(snapshot['sourceFileCount'], 1062659)
        self.assertIs(proof['releaseReady'], False)
        variant.verify_candidate_lock(self.lock, provenance=self.candidate, project_root=ROOT)
        self.assertEqual(variant.descriptor_for(self.lock).output, 'NeAntikComponentQA_20261016')
        fields = variant.report_source_fields(self.lock, project_root=ROOT)
        self.assertEqual(fields['sourceVariant'], subject.VARIANT)
        self.assertIn('component-completion', fields['sourceEvidenceMode'])
        self.assertIs(fields['freshWholeSourceTreeObserved'], False)

    def test_changed_missing_inherited_or_extra_source_refused(self):
        modes = ('drop', 'extra', 'preimage', 'postimage', 'parent-font', 'parent-security', 'old-binary')
        for mode in modes:
            p = copy.deepcopy(self.proof)
            if mode == 'drop': p['changes'].pop()
            elif mode == 'extra': p['changes'].append(copy.deepcopy(p['changes'][0]))
            elif mode in ('preimage', 'postimage'):
                p['changes'][0]['before' if mode == 'preimage' else 'after']['sha256'] = '0' * 64
            elif mode.startswith('parent-'):
                key = ('components/ungoogled/system_font_policy_mac.cc' if mode == 'parent-font'
                       else 'v8/src/codegen/compiler.cc')
                p['build']['sourcePostimages'][key] = '0' * 64
            else: p['build']['binaryBinding'] = copy.deepcopy(self.ancestor[2]['build']['binaryBinding'])
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                subject.verify_projection(ROOT, p, *self.ancestor)

    def test_failed_build_or_incomplete_observation_or_signing_refused(self):
        cases = [(('build', 'jobs'), True), (('build', 'exitCode'), 1),
                 (('build', 'oldInputsPreserved'), False), (('build', 'toolsPreserved'), False),
                 (('postbuildObservation', 'historicalBuildObservationRelabeled'), True),
                 (('postbuildObservation', 'ancestorFullSHA256'), '0' * 64),
                 (('postbuildObservation', 'sourceExecution'), True),
                 (('postbuildObservation', 'observation', 'sourceFileCount'), 1062655),
                 (('postbuildObservation', 'observation', 'fdSafeFullObservationVerified'), False),
                 (('postbuildObservation', 'observation', 'exactCoverageVerified'), False),
                 (('signing', 'buildReceiptSHA256'), '0' * 64),
                 (('signing', 'signerIdentity'), '0' * 40),
                 (('signing', 'runtimeTree', 'machoCount'), 15),
                 (('releaseReady',), True)]
        for keys, value in cases:
            p = copy.deepcopy(self.proof); target = p
            for key in keys[:-1]: target = target[key]
            target[keys[-1]] = value
            with self.subTest(keys=keys), self.assertRaises(ValueError):
                subject.verify_projection(ROOT, p, *self.ancestor)

    def test_mixed_development_receipts_refused_independently_of_outer_digest(self):
        original = subject.base.bound
        report = json.loads((ROOT / self.proof['developmentObservation']['path']).read_text())
        for keys in [('build', 'receiptSHA256'), ('sourceObservation', 'receiptSHA256'),
                     ('sourceObservation', 'entriesSHA256'), ('signedCodeClosure', subject.EXE),
                     ('sourceObservation', 'changedPaths')]:
            altered = copy.deepcopy(report); target = altered
            for key in keys[:-1]: target = target[key]
            target[keys[-1]] = [] if keys[-1] == 'changedPaths' else '0' * 64
            def mixed(root, name, digest):
                return altered if name == 'component-completion-development.json' else original(root, name, digest)
            with self.subTest(keys=keys), patch.object(subject.base, 'bound', side_effect=mixed):
                with self.assertRaises(ValueError): subject.verify_projection(ROOT, self.proof, *self.ancestor)

    def test_missing_marker_mixed_paths_and_old_output_refused(self):
        for mode in ('missing', 'unknown', 'predecessor-path'):
            lock = copy.deepcopy(self.lock)
            if mode == 'missing': lock.pop('sourceVariant')
            elif mode == 'unknown': lock['sourceVariant'] = 'future-unreviewed'
            else: lock['sourceContract'] = 'runtime/' + parent.PREFIX + '-source-contract.json'
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                variant.reviewed_lock_prefix(lock)
        with self.assertRaises(ValueError):
            subject.verify_candidate_document(self.candidate, project_root=ROOT, source_root=Path('/unobserved'))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); args = root / subject.ARGS_RELATIVE; args.parent.mkdir(parents=True); args.write_text('model args')
            snapshot = {'argsGN': {'relativePath': subject.ARGS_RELATIVE, 'sha256': subject.base.sha256_file(args)}}
            runtime = root / 'runtime'; runtime.mkdir()
            (runtime / (subject.PREFIX + '-port-candidate.json')).write_text('{}')
            raw = json.dumps(snapshot); (runtime / (subject.PREFIX + '-source-snapshot.json')).write_text(raw)
            import hashlib
            (runtime / (subject.PREFIX + '-source-contract.json')).write_text(json.dumps({'sourceSnapshotSHA256': hashlib.sha256(raw.encode()).hexdigest()}))
            with patch.object(variant, 'verify_candidate_lock'):
                self.assertEqual(verify_build_args(root, args, self.lock, root), args.resolve())
                old = root / parent.ARGS_RELATIVE; old.parent.mkdir(parents=True); old.write_bytes(args.read_bytes())
                with self.assertRaises(ValueError): verify_build_args(root, old, self.lock, root)

    def test_complete_packaging_keeps_both_predecessors_and_refuses_extra_members(self):
        with tempfile.TemporaryDirectory() as temp:
            evidence = Path(temp); packaged.process(ROOT, evidence, self.lock, copy=True)
            names = packaged.names(ROOT, self.lock)
            self.assertIn(parent.PREFIX + '-source-proof.json', names)
            self.assertIn(subject.PREFIX + '-source-proof.json', names)
            self.assertIn('component-updates-v1/native-tests/focused-target.patch', names)
            extra = evidence / 'component-updates-v1/unknown'; extra.write_text('extra')
            with self.assertRaisesRegex(ValueError, 'extra'): packaged.process(ROOT, evidence, self.lock)
            extra.unlink()
            member = evidence / 'component-updates-v1/development-observation.json'; member.unlink()
            member.symlink_to(ROOT / self.proof['developmentObservation']['path'])
            with self.assertRaisesRegex(ValueError, 'symlink'): packaged.process(ROOT, evidence, self.lock)


if __name__ == '__main__':
    unittest.main()
