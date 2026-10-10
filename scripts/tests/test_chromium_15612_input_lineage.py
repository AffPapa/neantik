import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
import chromium_15612_input_lineage as module
from chromium_15612_generated_cache import M156CacheError
from chromium_15612_receipt_projection import ProjectionError

H='a'*64

def fixture():
    labels=[]
    for prefix,count in [('common:',109),('macos:',20),('owned:',73)]:
        specials=sorted(n for n in module.SUPERSEDED if n.startswith(prefix))
        labels+=specials+[prefix+'input-'+str(i) for i in range(count-len(specials))]
    labels += ['semantic:input-'+str(i) for i in range(7)]+['canonical-input-'+str(i) for i in range(7)]
    base=[];semantic=[];canonical=[];full=[];current=H
    for index,label in enumerate(labels):
        series='base' if index<202 else 'semantic' if index<209 else 'canonical'
        superseded=label in module.SUPERSEDED
        after=current if superseded else hashlib.sha256(str(index).encode()).hexdigest()
        pre={'owned.py':current};post={'owned.py':after};current=after
        record={'series':series,'label':label,'patchPath':None if superseded else '@patches/owned.patch',
                'patchSHA256':None if superseded else H,'preimages':pre,'postimages':post,
                'applyOutputSHA256':hashlib.sha256(b'Reviewed native supersession').hexdigest() if superseded else H}
        origin={k:copy.deepcopy(v) for k,v in record.items() if k not in ['series','patchPath']}
        if series=='canonical':
            origin['sha256']=origin.pop('patchSHA256');origin['path']=record['patchPath']
        if superseded:
            origin.pop('applyOutputSHA256');origin.update(action='native-superseded',ported=False,originalPatchSHA256=H,
                                                        evidence={'decision.json':H})
        {'base':base,'semantic':semantic,'canonical':canonical}[series].append(origin);full.append(record)
    common={'commit':module.COMMIT,'nativeBuildStarted':False,'releaseReady':False}
    doc={module.BASE:{**common,'schemaVersion':1,'targetVersion':module.VERSION,
                      'status':'partial-shadow-replay-complete-still-unqualified','records':base},
         module.SEMANTIC:{**common,'status':'partial-shadow-replay-complete-still-unqualified',
                         'baseReplaySHA256':H,'records':semantic},
         module.CANONICAL:{**common,'status':'canonical-shadow-replay-complete-still-unqualified',
                          'baseReplaySHA256':H,'semanticReplaySHA256':H,'records':canonical},
         module.FULL:{'schemaVersion':1,'status':'full-source-replay-complete-unqualified',
                      'officialCommit':module.COMMIT,'officialTree':module.TREE,'releaseReady':False,'nativeBuildStarted':False,
                      'inputReceipts':{n:H for n in [module.BASE,module.SEMANTIC,module.CANONICAL]},
                      'acquisitionReceiptSHA256':H,'records':full},
         module.ACQUISITION:{'schemaVersion':1,'officialCommit':module.COMMIT,'officialTree':module.TREE,
                            'DEPS_SHA256':module.DEPS_SHA256,'hooksExecuted':False,'nativeBuildStarted':False,'releaseReady':False,
                            'git':151,'gcs':50,'cipd':39,'processed':240,
                            'records':{kind+str(i):{'kind':kind} for kind,count in [('git',151),('gcs',50),('cipd',39)] for i in range(count)}}}
    return {n:{'payload':data,'originalReceiptSHA256':H} for n,data in doc.items()}

class M156InputLineageTests(unittest.TestCase):
    def test_complete_order_separates212patches_from4supersessions(self):
        result=module.verify_lineage(fixture())
        self.assertEqual((result['orderedInputCount'],result['sourceChangingPatchCount'],result['nativeSupersessionCount']),(216,212,4))
        self.assertEqual(result['shadowApplyOutputBindingsCompared'],212)
        self.assertFalse(result['runtimeQualified']);self.assertFalse(result['releaseReady'])
        self.assertTrue(result['secondaryEvidenceClosureStillRequired'])
        self.assertTrue(result['subsequentCorrectionChainStillRequired'])

    def test_missing_truncated_and_reordered_stages_fail(self):
        changes=[]
        d=fixture();d.pop(module.BASE);changes.append(d)
        d=fixture();d[module.FULL]['payload']['records'].pop();changes.append(d)
        d=fixture();d[module.SEMANTIC]['payload']['records'].pop();changes.append(d)
        d=fixture();records=d[module.FULL]['payload']['records'];records[10],records[11]=records[11],records[10];changes.append(d)
        for d in changes:
            with self.assertRaises(M156CacheError):module.verify_lineage(d)

    def test_old_version_tree_schema_and_lineage_hash_fail(self):
        for name,changes in [(module.BASE,{'targetVersion':'155.0.8059.40'}),
                             (module.FULL,{'officialTree':'b'*40}),(module.FULL,{'schemaVersion':True}),
                             (module.ACQUISITION,{'schemaVersion':True}),(module.SEMANTIC,{'baseReplaySHA256':'b'*64}),
                             (module.CANONICAL,{'semanticReplaySHA256':'b'*64}),(module.FULL,{'acquisitionReceiptSHA256':'b'*64})]:
            d=fixture();d[name]['payload'].update(changes)
            with self.subTest(name=name,changes=changes),self.assertRaises(M156CacheError):module.verify_lineage(d)

    def test_acquisition_boolean_count_hook_execution_and_kind_fail(self):
        for changes in [{'git':True},{'processed':239},{'hooksExecuted':True},{'records':{}}]:
            d=fixture();d[module.ACQUISITION]['payload'].update(changes)
            with self.assertRaises(M156CacheError):module.verify_lineage(d)
        d=fixture();d[module.ACQUISITION]['payload']['records']['git0']['kind']='cipd'
        with self.assertRaises(M156CacheError):module.verify_lineage(d)

    def test_break_chain_even_when_full_and_shadow_agree_fail(self):
        d=fixture()
        for name in [module.FULL,module.BASE]:d[name]['payload']['records'][10]['preimages']['owned.py']='b'*64
        with self.assertRaisesRegex(M156CacheError,'preimage chain'):module.verify_lineage(d)

    def test_superseded_cannot_be_applied_or_mutated_or_unsupported(self):
        for field,value in [('patchPath','@patches/fake.patch'),('patchSHA256',H),('applyOutputSHA256',H)]:
            d=fixture();d[module.FULL]['payload']['records'][0][field]=value
            with self.assertRaises(M156CacheError):module.verify_lineage(d)
        for field,value in [('evidence',{}),('ported',True),('action','applied'),('originalPatchSHA256',None)]:
            d=fixture();d[module.BASE]['payload']['records'][0][field]=value
            with self.assertRaises(M156CacheError):module.verify_lineage(d)
        d=fixture()
        for name in [module.FULL,module.BASE]:d[name]['payload']['records'][0]['postimages']['owned.py']='b'*64
        with self.assertRaises(M156CacheError):module.verify_lineage(d)

    def test_applied_patch_cannot_be_noop_unbound_or_traversal(self):
        for field,value in [('patchPath',None),('patchSHA256',None),('applyOutputSHA256','not-hash'),('unreviewed',True)]:
            d=fixture();d[module.FULL]['payload']['records'][10][field]=value
            with self.assertRaises(M156CacheError):module.verify_lineage(d)
        d=fixture()
        for name in [module.FULL,module.BASE]:
            record=d[name]['payload']['records'][10];record['postimages']=dict(record['preimages'])
        with self.assertRaises(M156CacheError):module.verify_lineage(d)
        d=fixture()
        for name in [module.FULL,module.BASE]:
            record=d[name]['payload']['records'][10]
            record['preimages']={'../outside':H};record['postimages']={'../outside':'b'*64}
        with self.assertRaises(M156CacheError):module.verify_lineage(d)

    def test_wrapper_and_unbound_acquisition_hash_fail_with_stable_error(self):
        for bad in [None,[],{'payload':None,'originalReceiptSHA256':H},{'payload':{},'originalReceiptSHA256':None},{}]:
            d=fixture();d[module.ACQUISITION]=bad
            with self.assertRaises(M156CacheError):module.verify_lineage(d)
        d=fixture();d[module.ACQUISITION]['originalReceiptSHA256']=None
        d[module.FULL]['payload']['acquisitionReceiptSHA256']=None
        with self.assertRaises(M156CacheError):module.verify_lineage(d)
        with self.assertRaises(M156CacheError):module.verify_lineage([])

    def test_canonical_path_substitution_and_applied_path_traversal_fail(self):
        d=fixture();d[module.FULL]['payload']['records'][209]['patchPath']='@patches/replacement.patch'
        with self.assertRaisesRegex(M156CacheError,'Canonical patch path'):module.verify_lineage(d)
        for name in ['/private/unknown.patch','@patches/../outside.patch','@patches//invalid.patch']:
            d=fixture();d[module.FULL]['payload']['records'][10]['patchPath']=name
            with self.assertRaises(M156CacheError):module.verify_lineage(d)

    def test_current_authenticated_primary_bundle_real_semantics_and_pinned_tamper(self):
        root=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major/m156-source-public-preparation-attempt-4')
        if not root.is_dir():self.skipTest('Preserved owned primary bundle not available')
        result=module.verify_primary_bundle(root)
        self.assertEqual(len(result['stageReplayPostimages']),805)
        self.assertEqual(result['primaryProjectionRegistrySHA256'],module.PRIMARY_REGISTRY_SHA256)
        # Actual bytes copied privately, not a source build or public mutation.
        with tempfile.TemporaryDirectory(prefix='neantik-primary-pin-negative-') as temp:
            target=Path(temp)
            for item in root.iterdir():(target/item.name).write_bytes(item.read_bytes())
            name=module.FULL+'.projection.json';path=target/name
            d=json.loads(path.read_bytes());d['payload']['records'].pop()
            raw=(json.dumps(d,sort_keys=True,indent=2)+'\n').encode();path.write_bytes(raw)
            registry_path=target/'registry.json';registry=json.loads(registry_path.read_bytes())
            for item in registry['receipts']:
                if item['path']==name:item['projectionSHA256']=hashlib.sha256(raw).hexdigest()
            registry_path.write_text(json.dumps(registry,sort_keys=True,indent=2)+'\n')
            with self.assertRaises(ProjectionError):module.verify_primary_bundle(target)

if __name__=='__main__':unittest.main()
