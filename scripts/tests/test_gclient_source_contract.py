import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / 'scripts'))
from gclient_source_contract import verify_gclient_contract, verify_gclient_source
from gclient_source_evidence import EvidenceError


class GclientContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.plan_path, self.contract_path = root / 'plan.json', root / 'contract.json'
        inputs = PROJECT / 'runtime/chromium-153-inputs'
        git = json.loads((inputs / 'reviewed-gclient-git-recipe.json').read_text())
        self.plan = {'schemaVersion': 2, 'sourceMode': 'gclient',
            'targetChromiumVersion': '153.0.8010.36', 'officialChromiumCommit': git['root']['commit']}
        self.plan_path.write_text(json.dumps(self.plan))
        sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        self.contract = {'schemaVersion': 2, 'sourceMode': 'gclient',
            'binaryBindingStatus': 'pending-new-build', 'targetArchitecture': 'arm64',
            'targetChromiumVersion': '153.0.8010.36',
            'officialChromiumBase': {'repository': 'https://chromium.googlesource.com/chromium/src.git',
                'tag': '153.0.8010.36', 'commit': git['root']['commit'], 'tree': git['root']['tree'],
                'licenseSHA256': sha(PROJECT / 'runtime/licenses/Chromium-LICENSE')},
            'rebasePlanSHA256': sha(self.plan_path),
            'inputBundle': {'path': 'runtime/chromium-153-inputs/reviewed-input-bundle.json',
                            'sha256': sha(inputs / 'reviewed-input-bundle.json')},
            'buildToolFiles': {'out/Release/gn': '1' * 64},
            'ownedInputs': {'scripts/gclient_source_contract.py': sha(PROJECT / 'scripts/gclient_source_contract.py')}}

    def verify(self, value):
        self.contract_path.write_text(json.dumps(value))
        return verify_gclient_contract(PROJECT, self.contract_path, self.plan_path)

    def test_reviewed_reference_chain_and_no_binary_claim(self):
        self.assertEqual(self.verify(self.contract), self.contract)
        changed = copy.deepcopy(self.contract)
        changed['binaryBindingStatus'] = 'verified'
        with self.assertRaises(EvidenceError):
            self.verify(changed)

    def test_identity_hash_and_version_mutations_fail(self):
        for field in ('commit', 'tree'):
            changed = copy.deepcopy(self.contract)
            changed['officialChromiumBase'][field] = '0' * 40
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                self.verify(changed)
        for field, value in [('rebasePlanSHA256', '0' * 64), ('targetChromiumVersion', '152.0.0.0'),
                             ('schemaVersion', True), ('buildToolFiles', {})]:
            changed = copy.deepcopy(self.contract)
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                self.verify(changed)

    def test_stale_input_bundle_is_rejected(self):
        self.contract['inputBundle']['sha256'] = '0' * 64
        with self.assertRaises(EvidenceError):
            self.verify(self.contract)

    def test_live_tool_hashes_checked_before_and_after_input_scan(self):
        source = Path(self.temp.name) / 'source'
        tool = source / 'out/Release/gn'
        tool.parent.mkdir(parents=True)
        tool.write_bytes(b'reviewed tool')
        self.contract['buildToolFiles']['out/Release/gn'] = hashlib.sha256(tool.read_bytes()).hexdigest()
        self.verify(self.contract)
        with patch('gclient_source_contract.verify_input_bundle', return_value={'binaryBinding': 'not-attested'}) as scan:
            result = verify_gclient_source(PROJECT, source, self.contract_path, self.plan_path)
            self.assertEqual(result['binaryBinding'], 'not-attested')
            scan.assert_called_once()
        def mutate(*args):
            tool.write_bytes(b'changed tool')
            return {}
        with patch('gclient_source_contract.verify_input_bundle', side_effect=mutate):
            with self.assertRaises(EvidenceError):
                verify_gclient_source(PROJECT, source, self.contract_path, self.plan_path)
        with patch('gclient_source_contract.verify_input_bundle') as scan:
            with self.assertRaises(EvidenceError):
                verify_gclient_source(PROJECT, source, self.contract_path, self.plan_path)
            scan.assert_not_called()

    def test_provenance_dispatch_requires_live_scan_and_exact_document(self):
        from runtime_source_provenance import build_provenance, verify_document, SourceProvenanceError
        manifest = 'runtime/nevision-patches/series-153.json'
        self.contract['ownedInputs'][manifest] = hashlib.sha256((PROJECT / manifest).read_bytes()).hexdigest()
        self.verify(self.contract)
        options = dict(project_root=PROJECT, contract_path=self.contract_path,
                       rebase_plan_path=self.plan_path)
        source = Path(self.temp.name) / 'src'
        with patch('gclient_source_contract.verify_gclient_source', return_value={}) as scan:
            document = build_provenance(source, **options)
            scan.assert_called_once_with(PROJECT, source, self.contract_path, self.plan_path)
        self.assertEqual(document['schemaVersion'], 2)
        self.assertNotIn('liteArchive', document['officialChromiumBase'])
        verify_document(document, **options)
        from runtime_candidate_lock import expected_candidate_lock, verify_candidate_lock
        provenance_path = Path(self.temp.name) / 'provenance.json'
        candidate_path = Path(self.temp.name) / 'candidate.json'
        provenance_path.write_text(json.dumps(document))
        candidate = expected_candidate_lock(provenance_path, **options)
        self.assertEqual(candidate['schemaVersion'], 5)
        self.assertEqual(candidate['sourceMode'], 'gclient')
        self.assertNotIn('macPackaging', candidate)
        self.assertNotIn('liteArchive', candidate['fingerprintChromium'])
        candidate_path.write_text(json.dumps(candidate))
        verify_candidate_lock(candidate_path, provenance_path, **options)
        unbound = copy.deepcopy(self.contract)
        del unbound['ownedInputs'][manifest]
        with patch('runtime_candidate_lock.verify_contract', return_value=unbound):
            with self.assertRaisesRegex(SourceProvenanceError, 'must be bound'):
                expected_candidate_lock(provenance_path, **options)
        candidate['inputBundle']['sha256'] = '0' * 64
        candidate_path.write_text(json.dumps(candidate))
        with self.assertRaises(SourceProvenanceError):
            verify_candidate_lock(candidate_path, provenance_path, **options)
        changed = copy.deepcopy(document)
        changed['sourceChecks']['officialArchiveSHA256'] = 'verified'
        with self.assertRaises(SourceProvenanceError):
            verify_document(changed, **options)
        with patch('gclient_source_contract.verify_gclient_source', side_effect=EvidenceError('changed inputs')):
            with self.assertRaises(SourceProvenanceError):
                build_provenance(source, **options)

    def test_contract_change_during_live_scan_cannot_attest_new_contract(self):
        from runtime_source_provenance import build_provenance, SourceProvenanceError
        self.verify(self.contract)
        def replace_contract(*args):
            changed = copy.deepcopy(self.contract)
            changed['buildToolFiles']['out/Release/gn'] = '2' * 64
            self.contract_path.write_text(json.dumps(changed))
            return {}
        with patch('gclient_source_contract.verify_gclient_source', side_effect=replace_contract):
            with self.assertRaisesRegex(SourceProvenanceError, 'changed during'):
                build_provenance(Path(self.temp.name) / 'src', project_root=PROJECT,
                    contract_path=self.contract_path, rebase_plan_path=self.plan_path)


if __name__ == '__main__':
    unittest.main()
