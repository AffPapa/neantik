import copy
import hashlib
import json
import tempfile
import unittest
import os
from unittest import mock
from pathlib import Path
import chromium_15612_supplemental as module
from chromium_15612_generated_cache import M156CacheError
from chromium_15612_receipt_projection import ProjectionError,projection

ARTIFACTS=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major')

class M156SecondarySourceTests(unittest.TestCase):
    def setUp(self):
        if not (ARTIFACTS/'m156-DEPS-receipt.json').is_file():
            self.skipTest('Preserved source research receipts unavailable; not runtime evidence')
        self.roots={'evidence':ARTIFACTS,'research':ARTIFACTS.parents[3]/'.work-neantik-m15540-20261008'}
        self.primary=module.primary_documents(ARTIFACTS/'m156-source-public-preparation-attempt-4')
        self.docs={name:projection((ARTIFACTS/name).read_bytes(),name,self.roots) for name in module.PINS}

    def test_actual_decision_graph11edges10receipts_remains_unqualified(self):
        edges=module.verify_decision_edges(self.primary,self.docs)
        self.assertEqual(len(edges),11)
        self.assertEqual(len({e['targetName'] for e in edges}),10)
        self.assertEqual(edges[-1]['role'],'independently-pinned-pristine-hydration')
        with tempfile.TemporaryDirectory(prefix='neantik-supplemental-positive-') as temp:
            output=Path(temp)/'secondary'
            result=module.prepare_secondary(ARTIFACTS,ARTIFACTS/'m156-source-public-preparation-attempt-4',self.roots,output)
            self.assertFalse(result['runtimeQualified']);self.assertFalse(result['releaseReady'])
            self.assertTrue(result['toolPackagePayloadClosureStillRequired'])
            self.assertEqual(len(list(output.iterdir())),11)
            self.assertNotIn('/Users/',json.dumps(result))
            for path in output.iterdir():self.assertNotIn('/Users/',path.read_text())
            original=(output/'registry.json').read_bytes()
            with self.assertRaises(FileExistsError):module.prepare_secondary(ARTIFACTS,ARTIFACTS/'m156-source-public-preparation-attempt-4',self.roots,output)
            self.assertEqual((output/'registry.json').read_bytes(),original)

    def test_missing_extra_identity_or_qualified_receipt_refused(self):
        variants=[]
        d=copy.deepcopy(self.docs);d.pop(next(iter(d)));variants.append(d)
        d=copy.deepcopy(self.docs);d['extra.json']={};variants.append(d)
        for field,value in [('originalReceiptSHA256','b'*64),('receipt','substitute.json'),('releaseReady',True),('payload',None)]:
            d=copy.deepcopy(self.docs);d[next(iter(d))][field]=value;variants.append(d)
        for d in variants:
            with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)

    def test_native_decisions_must_match_their_stage_and_remain_unqualified(self):
        for name in ['m156-crubit-native-supersession.json','m156-enterprise-upload-native-include-supersession.json','m156-signin-chip-local-removal-supersession.json']:
            for field,value in [('commit','b'*40),('preimages',{})]:
                d=copy.deepcopy(self.docs);d[name]['payload'][field]=value
                with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)
        for field,value in [('nativeBuildVerified',True),('releaseReady',True),('toolchainProbes','old.json'),('checks',{})]:
            d=copy.deepcopy(self.docs);d['m156-crubit-native-supersession.json']['payload'][field]=value
            with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)

    def test_missing_target_is_specific_and_dependency_pins_cannot_move(self):
        for field,value in [('pin','b'*40),('targets',['third_party/devtools-frontend/src/unknown.py'])]:
            d=copy.deepcopy(self.docs);d['m156-devtools-absent-targets.json']['payload'][field]=value
            with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)
        d=copy.deepcopy(self.docs);path=next(iter(d['m156-devtools-source-receipts.json']['payload']))
        d['m156-devtools-source-receipts.json']['payload'][path]['pin']='b'*40
        with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)

    def test_nasm_pristine_cannot_be_substituted_by_later_postimage(self):
        d=copy.deepcopy(self.docs);path='third_party/nasm/config/config-mac.h'
        d['m156-nasm-source-receipts.json']['payload'][path]['sha256']=self.primary[module.BASE]['payload']['records'][122]['postimages'][path]
        with self.assertRaisesRegex(M156CacheError,'hydration preimage'):module.verify_decision_edges(self.primary,d)

    def test_probe_failures_boolean_exit_and_old_tool_package_refused(self):
        for value in [True,1,-1]:
            d=copy.deepcopy(self.docs);d['m156-pinned-toolchain-probes.json']['payload']['probes']['crubit']['exitCode']=value
            with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)
        d=copy.deepcopy(self.docs);d['m156-pinned-toolchain-receipt.json']['payload']['packages'][1]['kind']='no-crubit'
        with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)

    def test_valid_probe_log_cannot_attest_different_executable_or_package(self):
        d=copy.deepcopy(self.docs);d['m156-pinned-toolchain-probes.json']['payload']['probes']['crubit']['executableSHA256']='b'*64
        with self.assertRaisesRegex(M156CacheError,'frozen tool'):module.verify_decision_edges(self.primary,d)
        for field,value in [('url','https://example.invalid/old.tar.xz'),('archiveSHA256','b'*64),
                            ('size',True),('files',7259),('directory','/Users/test/private')]:
            d=copy.deepcopy(self.docs);d['m156-pinned-toolchain-receipt.json']['payload']['packages'][0][field]=value
            with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)
        d=copy.deepcopy(self.docs);d['m156-pinned-toolchain-receipt.json']['payload']['packages'][0]=None
        with self.assertRaises(M156CacheError):module.verify_decision_edges(self.primary,d)

    def test_raw_tamper_or_symlink_fails_before_output_creation(self):
        with tempfile.TemporaryDirectory(prefix='neantik-supplemental-negative-') as temp:
            root=Path(temp)
            for name in module.PINS:(root/name).write_bytes((ARTIFACTS/name).read_bytes())
            (root/'m156-DEPS.official').write_bytes((ARTIFACTS/'m156-DEPS.official').read_bytes())
            name='m156-nasm-source-receipts.json'
            raw=(root/name).read_bytes();(root/name).write_bytes(raw+b' ')
            with self.assertRaisesRegex(M156CacheError,'receipt changed'):
                module.prepare_secondary(root,ARTIFACTS/'m156-source-public-preparation-attempt-4',self.roots,root/'out')
            self.assertFalse((root/'out').exists())
            (root/name).unlink();(root/name).symlink_to(ARTIFACTS/name)
            with self.assertRaises(OSError):module.prepare_secondary(root,ARTIFACTS/'m156-source-public-preparation-attempt-4',self.roots,root/'out')

    def test_unknown_private_root_and_relabelled_GN_or_DEPS_fail(self):
        with self.assertRaises(ProjectionError):projection((ARTIFACTS/'m156-pinned-toolchain-receipt.json').read_bytes(),'m156-pinned-toolchain-receipt.json',{})
        for name in ['m156-crubit-native-supersession.json','m156-DEPS-receipt.json']:
            raw=(ARTIFACTS/name).read_bytes()
            with self.assertRaises(ProjectionError):projection(raw+b' ',name,self.roots)
            with self.assertRaises(ProjectionError):projection(raw,'unreviewed.json',self.roots)

    def test_actual_public_store_and_pinned_negative_controls(self):
        store=ARTIFACTS/'m156-secondary-source-preparation-attempt-4'
        if not store.is_dir():self.skipTest('Owned secondary preparation has not been created')
        primary=ARTIFACTS/'m156-source-public-preparation-attempt-4'
        verified=module.verify_secondary_bundle(store,primary)
        self.assertFalse(verified['runtimeQualified']);self.assertFalse(verified['releaseReady'])
        with tempfile.TemporaryDirectory(prefix='neantik-secondary-public-negative-') as temp:
            target=Path(temp)/'owned';target.mkdir()
            for path in store.iterdir():(target/path.name).write_bytes(path.read_bytes())
            name='m156-nasm-source-receipts.json.projection.json';path=target/name
            raw=path.read_bytes();doc=json.loads(raw);doc['payload']['third_party/nasm/config/config-mac.h']['pin']='b'*40
            changed=(json.dumps(doc,sort_keys=True,indent=2)+'\n').encode();path.write_bytes(changed)
            with self.assertRaisesRegex(M156CacheError,'projection changed'):module.verify_secondary_bundle(target,primary)
            registry_path=target/'registry.json';original=registry_path.read_bytes();reg=json.loads(original)
            for record in reg['receipts']:
                if record['name']==doc['receipt']:record['projectionSHA256']=hashlib.sha256(changed).hexdigest()
            registry_path.write_text(json.dumps(reg,sort_keys=True,indent=2)+'\n')
            with self.assertRaisesRegex(M156CacheError,'registry changed'):module.verify_secondary_bundle(target,primary)
            path.write_bytes(raw);registry_path.write_bytes(original)
            (target/'extra.json').write_bytes(b'{}')
            with self.assertRaisesRegex(M156CacheError,'extra file'):module.verify_secondary_bundle(target,primary)
            (target/'extra.json').unlink();path.unlink();path.symlink_to(store/name)
            with self.assertRaises(OSError):module.verify_secondary_bundle(target,primary)

class PortableOutputRaceTests(unittest.TestCase):
    def test_failed_sync_never_publishes_registry_or_removes_preserved_files(self):
        with tempfile.TemporaryDirectory(prefix='neantik-secondary-sync-fault-') as temp:
            output=Path(temp)/'owned'
            with mock.patch.object(module.os,'fsync',side_effect=OSError('synthetic sync failure')):
                with self.assertRaises(OSError):
                    module.write_new_store(output,{'one.json':{},'registry.json':{}})
            self.assertFalse((output/'registry.json').exists())
            self.assertEqual((output/'one.json').read_text(),'{}\n')

    def test_replacement_after_mkdir_writes_nothing_outside(self):
        with tempfile.TemporaryDirectory(prefix='neantik-secondary-mkdir-race-') as temp:
            root=Path(temp);output=root/'owned';outside=root/'synthetic-outside';outside.mkdir()
            mkdir=os.mkdir
            def replacing(name,*args,**kwargs):
                mkdir(name,*args,**kwargs)
                if name=='owned':
                    output.rename(root/'preserved');output.symlink_to(outside,target_is_directory=True)
            with mock.patch.object(module.os,'mkdir',side_effect=replacing):
                with self.assertRaises(OSError):module.write_new_store(output,{'one.json':{}})
            self.assertEqual(list(outside.iterdir()),[])
            self.assertEqual(list((root/'preserved').iterdir()),[])

    def test_replacement_after_first_open_is_confined_and_refused(self):
        with tempfile.TemporaryDirectory(prefix='neantik-secondary-write-race-') as temp:
            root=Path(temp);output=root/'owned';outside=root/'synthetic-outside';outside.mkdir()
            opening=os.open
            def replacing(name,*args,**kwargs):
                fd=opening(name,*args,**kwargs)
                if name=='one.json':
                    output.rename(root/'preserved');output.symlink_to(outside,target_is_directory=True)
                return fd
            with mock.patch.object(module.os,'open',side_effect=replacing):
                with self.assertRaisesRegex(M156CacheError,'directory replaced'):
                    module.write_new_store(output,{'one.json':{},'two.json':{}})
            self.assertEqual(list(outside.iterdir()),[])
            self.assertEqual([p.name for p in (root/'preserved').iterdir()],['one.json'])

if __name__=='__main__':unittest.main()
