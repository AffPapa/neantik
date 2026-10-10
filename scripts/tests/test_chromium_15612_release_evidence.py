"""Negatives for canonical156. Tests do not qualify a browser or release."""
import unittest,tempfile,sys,copy,json,hashlib
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import chromium_15612_release_evidence as e
from runtime_source_provenance import contract_paths_for_version,SourceProvenanceError

class M156ContractTests(unittest.TestCase):
    def test_exact_selector_does_not_fall_back_for_neighbor_versions(self):
        self.assertEqual(contract_paths_for_version(e.VERSION)[0].name,e.PREFIX+'-source-contract.json')
        for version in ['156.0.8078.13','156.0.8078.0','157.0.0.0']:
            with self.subTest(version=version),self.assertRaises(SourceProvenanceError):contract_paths_for_version(version)

    def test_closed_registry_rejects_rebaselined_derivative(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'registry.json').write_text('{"schemaVersion":1}')
            # A claimed original private SHA is not authority for new payload.
            with self.assertRaisesRegex(ValueError,'bound file changed'):e.evidence_documents(root)

    def test_duplicate_json_and_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);p=root/'proof.json';p.write_text('{"schemaVersion":1,"schemaVersion":2}')
            with self.assertRaises(ValueError):e.read_object(p,'proof')
            p.unlink();(root/'real').write_text('{}');p.symlink_to(root/'real')
            with self.assertRaises(ValueError):e.read_object(p,'proof')
            for name in ['../proof.json','/proof.json','./proof.json','a//b','a\\b','a\x00b']:
                with self.subTest(name=name),self.assertRaises(ValueError):e.safe_relative_regular(root,name)

    def test_unsigned_binding_rejects_changed_real_byte_and_wrong_build_path(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            candidate={'binaryBinding':{'candidateExecutableSHA256':'a'*64}}
            with self.assertRaisesRegex(ValueError,'canonical build args path'):
                e.verify_unsigned_binary_binding(root/'app',root/'out/Default/args.gn',candidate)

    def test_pending_cannot_be_promoted_by_self_report(self):
        with self.assertRaisesRegex(ValueError,'tuple promotion'):
            e.verify_packaged_tuple_qualification(Path('/unused'),Path('/unused'),{'verification':{'coherentAppleDeviceTuples':'verified'}})

    def test_source_closure_negatives_have_independent_originals(self):
        # Immutable actual public documents are read only. Mutation occurs only
        # in copies passed to the semantic checker, not in canonical evidence.
        root=Path(__file__).resolve().parents[2]/'runtime'/('chromium-15612-source-evidence')
        registry=json.loads((root/'registry.json').read_text());docs={}
        for record in registry['records']:
            raw=(root/record['path']).read_bytes();self.assertEqual(hashlib.sha256(raw).hexdigest(),record['projectionSHA256'])
            doc=json.loads(raw);docs[doc['receipt']]=doc
        e.verify_source_closure(docs)
        mutations=[('m156-native-build-attempt-9-state.json','exitCode',1),
                   ('m156-postbuild-attempt-9-full-fd-observation.json','fdSafeFullObservationVerified',False),
                   ('m156-attempt9-source-stage-closure.json','noncachedDomainSourcesReplayed',0),
                   ('m156-pruning-domain-preimage-origin-proof.json','verifiedPreimages',1),
                   ('m156-independent-domain-cache-replay-attempt-9.json','terminalStateSHA256','0'*64),
                   ('m156-subsequent-correction-lineage-attempt-9-v2.json','subsequentPatchCount',14),
                   ('m156-attempt9-unsigned-runtime-binding.json','callerDigestKind','canonical-source-manifest')]
        for name,key,value in mutations:
            changed=copy.deepcopy(docs);changed[name]['payload'][key]=value
            with self.subTest(name=name,key=key),self.assertRaises(ValueError):e.verify_source_closure(changed)

if __name__=='__main__':unittest.main()

class CanonicalMetadataRebaseNegatives(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project=Path(__file__).resolve().parents[2];runtime=cls.project/'runtime'
        cls.contract=json.loads((runtime/(e.PREFIX+'-source-contract.json')).read_text())
        cls.docs={n:json.loads((runtime/(e.PREFIX+'-'+n+'.json')).read_text()) for n in ['source-input-manifest','source-snapshot','toolchain-lock','rebase-plan']}
        registry=json.loads((runtime/(e.PREFIX+'-source-evidence/registry.json')).read_text())
        cls.evidence={}
        for rec in registry['records']:
            doc=json.loads((runtime/(e.PREFIX+'-source-evidence')/rec['path']).read_text());cls.evidence[doc['receipt']]=doc

    def verify(self,docs):
        def selected(root,name,expected):
            # Simulate caller rehashing canonical documents. Independently
            # pinned original/projection proof remains the real authority.
            return docs[name[len(e.PREFIX)+1:-5]]
        with patch.object(e,'read_object',return_value=self.contract),patch.object(e,'bound',side_effect=selected),patch.object(e,'evidence_documents',return_value=self.evidence):
            return e.verify_contract(self.project)

    def test_consistent_metadata_passes_and_self_rebased_changes_fail(self):
        self.verify(copy.deepcopy(self.docs))
        cases=[('source-input-manifest','originalPrebuildSnapshotSHA256','0'*64),
               ('source-input-manifest','originalFreezeInputsSHA256',{}),
               ('source-input-manifest','originalFullFDObservationSHA256','0'*64),
               ('source-input-manifest','originalSourceStageClosureSHA256','0'*64),
               ('source-input-manifest','originalTerminalStateSHA256','0'*64),
               ('toolchain-lock','CIPDOriginOriginalSHA256','0'*64),
               ('toolchain-lock','nodeOriginOriginalSHA256','0'*64),
               ('toolchain-lock','pythonProducerSHA256','0'*64),
               ('toolchain-lock','xcodeVersion','unreviewed'),
               ('toolchain-lock','sdkVersion','unreviewed'),
               ('toolchain-lock','jobs',20),
               ('rebase-plan','orderedReplayOriginalSHA256','0'*64),
               ('rebase-plan','lateCorrectionLineageOriginalSHA256','0'*64)]
        for name,key,value in cases:
            changed=copy.deepcopy(self.docs);changed[name][key]=value
            with self.subTest(name=name,key=key),self.assertRaises(ValueError):self.verify(changed)
        for name in ['upstreamCommonOverlay','upstreamMacPackaging']:
            for key,value in [('seriesSHA256','0'*64),('patchCount',0),('tree','0'*40)]:
                changed=copy.deepcopy(self.docs);changed['rebase-plan'][name][key]=value
                with self.subTest(name=name,key=key),self.assertRaises(ValueError):self.verify(changed)
