"""Actual source proof and broken-projection controls; no browser launch."""
import copy
import json
import unittest
from pathlib import Path
from unittest.mock import patch
import chromium_15612_font_release_evidence as subject
import chromium_15612_variant as variant

ROOT = Path(__file__).resolve().parents[2]


class M156FontSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract, cls.snapshot = subject.base.verify_contract(ROOT)
        cls.proof = subject._object(ROOT, 'source-proof')
        cls.candidate = subject._object(ROOT, 'port-candidate')
        cls.lock = subject.base.read_object(ROOT / 'runtime' / ('fingerprint-' + subject.PREFIX + '.lock.json'), 'font lock')

    def test_real_reviewed_source_variant_and_legacy_stay_distinct(self):
        variant.verify_candidate_lock(self.lock, provenance=self.candidate, project_root=ROOT)
        contract, snapshot, proof = subject.verify_contract(ROOT)
        self.assertEqual(proof, self.proof)
        self.assertEqual(snapshot['sourceFileCount'], 1062655)
        self.assertEqual(contract['baseSourceContractSHA256'], self.proof['base']['sourceContractSHA256'])
        self.assertIs(proof['releaseReady'], False)
        ancestor = subject.base.read_object(ROOT / 'runtime/chromium-15612-port-candidate.json', 'ancestor')
        ancestor_lock = subject.base.read_object(ROOT / 'runtime/fingerprint-chromium-15612.lock.json', 'ancestor lock')
        variant.verify_candidate_lock(ancestor_lock, provenance=ancestor, project_root=ROOT)
        self.assertNotEqual(ancestor['binaryBinding']['candidateFrameworkSHA256'], self.candidate['binaryBinding']['candidateFrameworkSHA256'])

    def test_semantic_projection_controls_detect_missing_and_mixed_proof(self):
        changes = self.proof['changes']
        first = next(i for i, x in enumerate(changes) if x['before'] is not None)
        def change(fn):
            p = copy.deepcopy(self.proof); fn(p); return p
        mutations = [
            lambda p: p.update(sourceVariant='font-system-v2'),
            lambda p: p.update(releaseReady=True),
            lambda p: p.update(schemaVersion=True),
            lambda p: p['base'].update(fullFDObservationSHA256='0' * 64),
            lambda p: p['sourceContracts'].pop(subject.MANIFESTS[-1]),
            lambda p: p['changes'].pop(),
            lambda p: p['changes'].reverse(),
            lambda p: p['changes'][0].update(path='../outside'),
            lambda p: p['changes'][first]['before'].update(sha256='0' * 64),
            lambda p: p['changes'][first]['after'].update(sha256='0' * 64),
            lambda p: p['qaOwnedInputs'].update({'runtime/font-policy-v1/native-probe/BUILD.gn': '0' * 64}),
            lambda p: p['postbuildObservation'].update(historicalBuildObservationRelabeled=True),
            lambda p: p['postbuildObservation']['observation'].update(exactCoverageVerified=False),
            lambda p: p['postbuildObservation']['observation'].update(explicitCopyGroupsObserved=82),
            lambda p: p['build'].update(jobs=True),
            lambda p: p['build'].update(argsSHA256='0' * 64),
            lambda p: p['build']['sourcePostimages'].update({'components/ungoogled/system_font_source.cc': '0' * 64}),
            lambda p: p['signing'].update(buildReceiptSHA256='0' * 64),
            lambda p: p['signing'].update(signerIdentity='0' * 40),
            lambda p: p['signing']['runtimeTree'].update(digest='0' * 64),
        ]
        for index, fn in enumerate(mutations):
            with self.subTest(control=index), self.assertRaises((ValueError, KeyError)):
                subject.verify_projection(ROOT, change(fn), self.contract, self.snapshot)

    def test_golden_proof_hash_is_an_independent_boundary(self):
        original = subject.base.bound
        def corrupt(root, name, expected):
            if name == subject.PREFIX + '-source-proof.json':
                self.assertEqual(expected, subject.PROOF_SHA256)
                raise ValueError('proof bytes drift')
            return original(root, name, expected)
        with patch.object(subject.base, 'bound', side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, 'proof bytes drift'):
                subject.verify_contract(ROOT)

    def test_candidate_and_lock_reject_label_reuse_and_unrelated_policy_changes(self):
        for key, value in [('sourceVariant', None), ('schemaVersion', True), ('releaseReady', True),
                           ('sourceSnapshotSHA256', '0' * 64)]:
            changed = copy.deepcopy(self.candidate); changed[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                subject.verify_candidate_document(changed, project_root=ROOT)
        old = subject.base.read_object(ROOT / 'runtime/chromium-15612-port-candidate.json', 'ancestor')
        changed = copy.deepcopy(self.candidate); changed['binaryBinding'] = old['binaryBinding']
        with self.assertRaises(ValueError):
            subject.verify_candidate_document(changed, project_root=ROOT)
        changed = copy.deepcopy(self.lock); changed['commonChromium']['commit'] = '0' * 40
        with self.assertRaises(ValueError):
            subject.verify_candidate_lock(changed, provenance=self.candidate, project_root=ROOT)
        with self.assertRaisesRegex(ValueError, 'cannot claim a new live observation'):
            subject.verify_candidate_document(self.candidate, project_root=ROOT, source_root=Path('/not-observed'))


if __name__ == '__main__':
    unittest.main()
