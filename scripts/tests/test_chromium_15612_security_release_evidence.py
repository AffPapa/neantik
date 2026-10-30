"""Source proof controls only; these tests do not launch/qualify a browser."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import chromium_15612_security_release_evidence as subject
import chromium_15612_font_release_evidence as parent
import chromium_15612_variant as variant
import chromium_15612_packaged_evidence as packaged
from runtime_build_path import verify_build_args


class SecuritySourceEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ancestor = parent.verify_contract(ROOT)
        cls.proof = json.loads((ROOT / 'runtime' / (subject.PREFIX + '-source-proof.json')).read_text())

    def verify(self, proof):
        subject.verify_projection(ROOT, proof, *self.ancestor)

    def test_exact_actual_source_build_sign_family(self):
        contract, snapshot, proof = subject.verify_contract(ROOT)
        self.assertEqual(snapshot['sourceFileCount'], 1062659)
        self.assertEqual(contract['sourceVariant'], subject.VARIANT)
        self.assertIs(proof['releaseReady'], False)
        candidate = json.loads((ROOT / 'runtime' / (subject.PREFIX + '-port-candidate.json')).read_text())
        lock = json.loads((ROOT / 'runtime' / ('fingerprint-' + subject.PREFIX + '.lock.json')).read_text())
        subject.verify_candidate_lock(lock, provenance=candidate, project_root=ROOT)

    def test_missing_or_extra_patch_path_is_refused(self):
        for change in ('missing', 'extra', 'changed'):
            p = copy.deepcopy(self.proof)
            if change == 'missing':
                p['changes'].pop()
            elif change == 'extra':
                p['changes'].append(copy.deepcopy(p['changes'][-1]))
            else:
                next(c['after'] for c in p['changes'] if c['after'])['sha256'] = '0' * 64
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify(p)

    def test_no_old_scan_or_incomplete_scan_can_qualify_source(self):
        for field, value in (('sourceFileCount', 1062655), ('exactCoverageVerified', False),
                             ('fdSafeFullObservationVerified', False), ('explicitCopyGroupsObserved', 82)):
            p = copy.deepcopy(self.proof)
            p['postbuildObservation']['observation'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(p)

    def test_wrong_predecessor_or_relabeling_refused(self):
        for field, value in (('historicalBuildObservationRelabeled', True),
                             ('ancestorFullSHA256', '0' * 64), ('deletedPathCount', 3248),
                             ('sourceExecution', True)):
            p = copy.deepcopy(self.proof)
            p['postbuildObservation'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(p)

    def test_changed_font_or_missing_build_input_refused(self):
        font_path = next(iter(self.ancestor[2]['build']['sourcePostimages']))
        for mode in ('alter', 'drop'):
            p = copy.deepcopy(self.proof)
            if mode == 'alter':
                p['build']['sourcePostimages'][font_path] = '0' * 64
            else:
                p['build']['sourcePostimages'].pop(font_path)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.verify(p)

    def test_failed_build_or_changed_tools_refused(self):
        for field, value in (('exitCode', 1), ('jobs', True), ('toolsUnchanged', False),
                             ('sourcePostimagesUnchanged', False), ('sourceManifestUnchanged', False)):
            p = copy.deepcopy(self.proof)
            p['build'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(p)

    def test_wrong_signature_lineage_or_closure_refused(self):
        for mode in ('receipt', 'identity', 'unknown-code', 'missing-code', 'tree'):
            p = copy.deepcopy(self.proof)
            sign = p['signing']
            if mode == 'receipt':
                sign['buildReceiptSHA256'] = '0' * 64
            elif mode == 'identity':
                sign['signerIdentity'] = '0' * 40
            elif mode == 'unknown-code':
                sign['signedCodeClosure']['Contents/Unknown'] = sign['signedCodeClosure'].pop(subject.EXE)
            elif mode == 'missing-code':
                sign['signedCodeClosure'].pop(subject.EXE)
            else:
                sign['runtimeTree']['machoCount'] = 15
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.verify(p)

    def test_exact_unsigned_output_and_args_binding_cannot_inherit_font_hash(self):
        p = copy.deepcopy(self.proof)
        p['build']['binaryBinding'] = copy.deepcopy(self.ancestor[2]['build']['binaryBinding'])
        with self.assertRaises(ValueError):
            self.verify(p)

    def test_future_release_claim_and_unknown_fields_refused(self):
        for mode in ('ready', 'extra', 'no-limitations'):
            p = copy.deepcopy(self.proof)
            if mode == 'ready':
                p['releaseReady'] = True
            elif mode == 'extra':
                p['runtimeQualified'] = True
            else:
                p['limitations'] = []
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.verify(p)

    def test_mixed_candidate_paths_and_unsigned_live_claim_refused(self):
        candidate = json.loads((ROOT / 'runtime' / (subject.PREFIX + '-port-candidate.json')).read_text())
        with self.assertRaises(ValueError):
            subject.verify_candidate_document(candidate, project_root=ROOT, source_root=Path('/tmp/unobserved'))
        candidate['sourceVariant'] = parent.VARIANT
        with self.assertRaises(ValueError):
            subject.verify_candidate_document(candidate, project_root=ROOT)

    def test_selected_new_output_is_required_even_with_identical_args_bytes(self):
        lock = json.loads((ROOT / 'runtime' / ('fingerprint-' + subject.PREFIX + '.lock.json')).read_text())
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            args = source / subject.ARGS_RELATIVE
            args.parent.mkdir(parents=True)
            # Only the path and digest mechanics are injected; actual family
            # authentication has its independent positive test above.
            args.write_text('owned-model-args')
            snapshot = {'argsGN': {'relativePath': subject.ARGS_RELATIVE, 'sha256': subject.base.sha256_file(args)}}
            runtime = source / 'runtime'
            runtime.mkdir()
            (runtime / (subject.PREFIX + '-port-candidate.json')).write_text('{}')
            raw = json.dumps(snapshot)
            (runtime / (subject.PREFIX + '-source-snapshot.json')).write_text(raw)
            import hashlib
            (runtime / (subject.PREFIX + '-source-contract.json')).write_text(json.dumps({
                'sourceSnapshotSHA256': hashlib.sha256(raw.encode()).hexdigest()}))
            with patch.object(variant, 'verify_candidate_lock'):
                self.assertEqual(verify_build_args(source, args, lock, source), args.resolve())
                copied = source / parent.ARGS_RELATIVE
                copied.parent.mkdir(parents=True)
                copied.write_bytes(args.read_bytes())
                with self.assertRaisesRegex(ValueError, 'exact M156 qualified'):
                    verify_build_args(source, copied, lock, source)

    def test_packaged_security_inherits_font_proof_and_refuses_extra_or_linked_members(self):
        lock = json.loads((ROOT / 'runtime' / ('fingerprint-' + subject.PREFIX + '.lock.json')).read_text())
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            packaged.process(ROOT, evidence, lock, copy=True)
            names = packaged.names(ROOT, lock)
            self.assertIn(parent.PREFIX + '-source-proof.json', names)
            self.assertIn(subject.PREFIX + '-source-proof.json', names)
            self.assertEqual(sum(n.endswith('.patch') and n.startswith('security-backports-') for n in names), 8)
            extra = evidence / 'security-backports-20261015/unreviewed.txt'
            extra.write_text('extra')
            with self.assertRaisesRegex(ValueError, 'extra'):
                packaged.process(ROOT, evidence, lock)
            extra.unlink()
            member = evidence / 'security-backports-20261015/CHROMIUM_LICENSE.txt'
            raw = member.read_bytes()
            member.unlink()
            member.symlink_to(ROOT / 'runtime/security-backports-20261015/CHROMIUM_LICENSE.txt')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                packaged.process(ROOT, evidence, lock)
            member.unlink()
            member.write_bytes(raw + b'corrupted')
            with self.assertRaisesRegex(ValueError, 'differs'):
                packaged.process(ROOT, evidence, lock)

    def test_schema_numbers_are_not_booleans_or_floats(self):
        read_object = subject._object
        for role, value in (('source-input-manifest', True), ('source-contract', 4.0)):
            def altered(project, suffix, *, selected=role, invalid=value):
                document = read_object(project, suffix)
                if suffix == selected:
                    document['schemaVersion'] = invalid
                return document
            with self.subTest(role=role), patch.object(subject, '_object', side_effect=altered):
                with self.assertRaises(ValueError):
                    subject.verify_contract(ROOT)


if __name__ == '__main__':
    unittest.main()
