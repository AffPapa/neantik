"""Bounded negative controls for the additive contract; no browser qualification."""
import copy,json,sys,tempfile,unittest,shutil
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import chromium_15540_semantic_corrections as subject
from chromium_15540_release_evidence import M15540EvidenceError
PROJECT=Path(__file__).resolve().parents[2]

class SemanticCorrectionTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
  self.document=json.loads((PROJECT/'runtime/chromium-15540-semantic-v1-corrections-manifest.json').read_text())
  files=['runtime/chromium-15540-source-contract.json','runtime/chromium-15540-source-snapshot.json','runtime/chromium-15540-source-evidence/ordered-patch-replay.json']+[p['path'] for p in self.document['patches']]
  for name in files:
   dest=self.root/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(PROJECT/name,dest)
 def rejects(self,document):
  with self.assertRaises(M15540EvidenceError):subject.verify_manifest(self.root,document)
 def test_exact_two_vectors_and_five_files(self):
  self.assertEqual(len(subject.verify_manifest(self.root,self.document)),5)
 def test_unknown_variant_and_extra_key(self):
  for key,value in [('semanticCorrectionSet','optional'),('schemaVersion',2),('schemaVersion',True),('releaseReady',True),('unbound',False)]:
   d=copy.deepcopy(self.document);d[key]=value;self.rejects(d)
 def test_missing_and_reordered_patches(self):
  for patches in [[],self.document['patches'][:1],list(reversed(self.document['patches']))]:
   d=copy.deepcopy(self.document);d['patches']=patches;self.rejects(d)
 def test_missing_extra_duplicate_or_traversal_file(self):
  for mutation in ('missing','extra','duplicate','traversal','absolute'):
   d=copy.deepcopy(self.document);files=d['patches'][0]['files']
   if mutation=='missing':files.pop()
   elif mutation=='extra':files.append(copy.deepcopy(files[0]))
   elif mutation=='duplicate':files[1]=copy.deepcopy(files[0])
   else:files[0]['path']='../escape' if mutation=='traversal' else '/tmp/escape'
   self.rejects(d)
 def test_base_and_patch_digest_changes_rejected(self):
  for key in ('baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256'):
   d=copy.deepcopy(self.document);d[key]='0'*64;self.rejects(d)
  p=self.root/self.document['patches'][0]['path'];p.write_bytes(p.read_bytes()+b'\n');self.rejects(self.document)
 def test_symlink_patch_rejected(self):
  p=self.root/self.document['patches'][0]['path'];data=p.read_bytes();p.unlink();target=self.root/'foreign';target.write_bytes(data);p.symlink_to(target);self.rejects(self.document)
 def test_malformed_source_hash(self):
  for value in ('',None,'g'*64,'0'*63):
   d=copy.deepcopy(self.document);d['patches'][0]['files'][0]['postimageSHA256']=value;self.rejects(d)
 def test_v2_additive_webgl_retains_v1(self):
  d=json.loads((PROJECT/'runtime/chromium-15540-semantic-v2-corrections-manifest.json').read_text())
  patch=PROJECT/d['patches'][-1]['path'];dest=self.root/d['patches'][-1]['path'];shutil.copyfile(patch,dest)
  self.assertEqual(len(subject.verify_manifest(self.root,d)),6)
  self.assertEqual(len(subject.verify_manifest(self.root,self.document)),5)
 def test_v3_additive_session_boundary(self):
  d=json.loads((PROJECT/'runtime/chromium-15540-semantic-v3-corrections-manifest.json').read_text())
  for item in d['patches'][2:]:shutil.copyfile(PROJECT/item['path'],self.root/item['path'])
  self.assertEqual(len(subject.verify_manifest(self.root,d)),7)
  d['patches'].pop();self.rejects(d)
 def test_invalid_path_type_rejected(self):
  for value in (None,[],{}):
   d=copy.deepcopy(self.document);d['patches'][0]['files'][0]['path']=value;self.rejects(d)
 def test_duplicate_document_key_and_oversize(self):
  p=self.root/'document.json';p.write_text('{"schemaVersion":1,"schemaVersion":2}')
  with self.assertRaises(M15540EvidenceError):subject.object_at(p)
  p.write_bytes(b' '*65537)
  with self.assertRaises(M15540EvidenceError):subject.object_at(p)

if __name__=='__main__':unittest.main()
