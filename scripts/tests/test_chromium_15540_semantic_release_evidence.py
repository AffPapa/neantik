"""Additive document/delta regression controls; no claim of runtime qualification."""
import copy,json,shutil,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import chromium_15540_release_evidence as base
import chromium_15540_semantic_corrections as corrections
import chromium_15540_semantic_release_evidence as semantic
import chromium_15540_variant as variant
PROJECT=Path(__file__).resolve().parents[2];PREFIX='chromium-15540-semantic-v3'

class AdditiveEvidenceTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  shutil.copytree(PROJECT/'runtime',self.root/'runtime')
  plan=base.read_object(PROJECT/'runtime/chromium-15540-rebase-plan.json','plan')
  overlay=base.read_object(PROJECT/'runtime/chromium-15540-source-evidence/reviewed-source-overlay.json','overlay')
  for item in plan['reviewedTools']+overlay['tupleRendererInputs']:
   target=self.root/item['path'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(PROJECT/item['path'],target)
  r=self.root/'runtime';manifest=corrections.object_at(r/(PREFIX+'-corrections-manifest.json'));receipt=corrections.object_at(r/(PREFIX+'-corrections-receipt.json'));original,_=base.verify_contract(self.root)
  self.manifest,self.receipt=manifest,receipt
  binding={k:receipt[k] for k in ('semanticCorrectionSet','baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256','correctionsManifestSHA256','sourceInputSnapshotSHA256')};binding['correctionsReceiptSHA256']=base.sha256_file(r/(PREFIX+'-corrections-receipt.json'))
  snapshot=base.read_object(r/(PREFIX+'-prebuild-source-snapshot.json'),'prebuild');self.write('source-snapshot',snapshot)
  inputs={**binding,'schemaVersion':1,'chromiumVersion':base.VERSION,'status':'source-reconstructed','sourceInputsReady':True,'releaseReady':False,'sourceSnapshotSHA256':receipt['sourceInputSnapshotSHA256'],'buildArgsSHA256':original['buildArgsSHA256']};self.write('source-input-manifest',inputs)
  contract={**original,**binding,'schemaVersion':3,'sourceSnapshotSHA256':receipt['sourceInputSnapshotSHA256'],'sourceInputManifestSHA256':base.sha256_file(r/(PREFIX+'-source-input-manifest.json'))};self.write('source-contract',contract)
  self.candidate={**binding,'schemaVersion':1,'status':'candidate-bound','releaseReady':False,'targetChromiumVersion':base.VERSION,'targetArchitecture':'arm64','sourceContractSHA256':base.sha256_file(r/(PREFIX+'-source-contract.json')),'sourceInputManifestSHA256':contract['sourceInputManifestSHA256'],'sourceSnapshotSHA256':contract['sourceSnapshotSHA256'],'binaryBinding':{'status':'bound-to-built-candidate','sourceVersion':base.VERSION,'architecture':'arm64','argsGNSHA256':original['buildArgsSHA256'],'candidateExecutableSHA256':'1'*64,'candidateFrameworkSHA256':'2'*64},'policy':'Source and unsigned build only; signed runtime and release gates remain required.'};self.write('port-candidate',self.candidate)
  self.lock=base.read_object(r/'fingerprint-chromium-15540.lock.json','base lock');self.lock.update(binding,sourceContract='runtime/'+PREFIX+'-source-contract.json',sourceContractSHA256=self.candidate['sourceContractSHA256'],sourceProvenance='runtime/'+PREFIX+'-port-candidate.json',sourceProvenanceSHA256=base.sha256_file(r/(PREFIX+'-port-candidate.json')));self.lock['binaryBinding']={'requiredEvidence':self.lock['sourceProvenance'],'status':'bound-by-source-candidate-and-runtime-report'};self.lock['verification']={'coherentAppleDeviceTuples':'pending-runtime-evidence','scope':'Fresh signed runtime semantics, realms, route and release gates required; prior runtime PASS not inherited.'};self.write_lock()
 def write(self,name,d):
  (self.root/'runtime'/(PREFIX+'-'+name+'.json')).write_text(json.dumps(d,sort_keys=True,indent=2)+'\n')
 def write_lock(self):(self.root/'runtime'/('fingerprint-'+PREFIX+'.lock.json')).write_text(json.dumps(self.lock,indent=2)+'\n')
 def test_exact_bound_documents_only(self):
  variant.verify_candidate_lock(self.lock,provenance=self.candidate,project_root=self.root)
  self.assertEqual(self.lock['verification']['coherentAppleDeviceTuples'],'pending-runtime-evidence')
 def test_canonical_lock_float_schema_or_integer_boolean_rejected(self):
  for key,value in (('schemaVersion',4.0),('releaseReady',0)):
   old=self.lock[key];self.lock[key]=value;self.write_lock()
   with self.assertRaisesRegex(base.M15540EvidenceError,'schema type'):semantic.verify_candidate_lock(self.lock,provenance=self.candidate,project_root=self.root)
   self.lock[key]=old
 def test_unknown_stripped_and_mismatched_variant(self):
  for action in ('unknown','stripped','mismatch'):
   d=copy.deepcopy(self.candidate);lock=copy.deepcopy(self.lock)
   if action=='unknown':d['semanticCorrectionSet']='optional'
   elif action=='stripped':d.pop('semanticCorrectionSet')
   else:lock['semanticCorrectionSet']='canvas-audio-native-v1'
   with self.assertRaises(base.M15540EvidenceError):variant.verify_candidate_lock(lock,provenance=d,project_root=self.root)
 def test_receipt_missing_or_forged_aggregate(self):
  d=copy.deepcopy(self.receipt);d['sourceInputSnapshotSHA256']='0'*64
  with self.assertRaisesRegex(base.M15540EvidenceError,'Unreviewed'):semantic.verify_receipt(self.root,self.manifest,d)
  (self.root/'runtime'/(PREFIX+'-corrections-receipt.json')).unlink()
  with self.assertRaises(base.M15540EvidenceError):semantic.verify_candidate_document(self.candidate,project_root=self.root)
 def test_schema_float_bool_and_false_release_flags(self):
  for value in (1.0,True):
   d=copy.deepcopy(self.candidate);d['schemaVersion']=value;self.write('port-candidate',d)
   with self.assertRaises(base.M15540EvidenceError):semantic.verify_candidate_document(d,project_root=self.root)
  self.write('port-candidate',self.candidate)
  contract=base.read_object(self.root/'runtime'/(PREFIX+'-source-contract.json'),'contract');contract['schemaVersion']=3.0;self.write('source-contract',contract)
  with self.assertRaises(base.M15540EvidenceError):semantic.verify_candidate_document(self.candidate,project_root=self.root)
 def test_old_framework_cannot_inherit_corrections(self):
  d=copy.deepcopy(self.candidate);d['binaryBinding']['candidateFrameworkSHA256']=base.read_object(self.root/'runtime/chromium-15540-port-candidate.json','old')['binaryBinding']['candidateFrameworkSHA256'];self.write('port-candidate',d)
  with self.assertRaisesRegex(base.M15540EvidenceError,'Old runtime'):semantic.verify_candidate_document(d,project_root=self.root)
 def test_inherited_runtime_pass_rejected(self):
  self.lock['verification']={'coherentAppleDeviceTuples':'verified'};self.write_lock()
  with self.assertRaisesRegex(base.M15540EvidenceError,'inherited'):semantic.verify_candidate_lock(self.lock,provenance=self.candidate,project_root=self.root)
 def test_lock_paths_and_receipt_apply_order(self):
  self.lock['sourceContract']='runtime/chromium-15540-source-contract.json'
  with self.assertRaises(base.M15540EvidenceError):variant.reviewed_lock_prefix(self.lock)
  d=copy.deepcopy(self.receipt);d['appliedPatches'].reverse()
  with self.assertRaises(base.M15540EvidenceError):semantic.verify_receipt(self.root,self.manifest,d)
 def test_receipt_symlink_and_mode_types(self):
  for value in (True,'100644',420.0):
   d=copy.deepcopy(self.receipt);d['appliedPatches'][0]['files'][0]['mode']=value
   with self.assertRaises(base.M15540EvidenceError):semantic.verify_receipt(self.root,self.manifest,d)
  p=self.root/'runtime'/(PREFIX+'-corrections-receipt.json');p.unlink();p.symlink_to(PROJECT/'runtime'/(PREFIX+'-corrections-receipt.json'))
  with self.assertRaises(base.M15540EvidenceError):semantic.verify_candidate_document(self.candidate,project_root=self.root)
 def test_other_policies_not_silently_changed(self):
  contract=base.read_object(self.root/'runtime'/(PREFIX+'-source-contract.json'),'contract');contract['safeBrowsingMode']=1;self.write('source-contract',contract)
  with self.assertRaises(base.M15540EvidenceError):semantic.verify_contract(self.root,self.candidate)

if __name__=='__main__':unittest.main()
