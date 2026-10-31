"""Cumulative patch dependency controls, not runtime qualification."""
import copy,json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import chromium_15540_semantic_corrections as corrections
import chromium_15540_semantic_release_evidence as semantic
import chromium_15540_generated_cache as cache
from chromium_15540_source_snapshot import compact_snapshot
ROOT=Path(__file__).resolve().parents[2]

class V4LineageTests(unittest.TestCase):
 def setUp(self):
  self.manifest=json.loads((ROOT/'runtime/chromium-15540-semantic-v4-corrections-manifest.json').read_text())
 def test_exact_six_vectors_and_eleven_unique_postimages(self):
  images=corrections.verify_manifest(ROOT,self.manifest)
  self.assertEqual(len(images),11)
  overlapping=self.manifest['patches'][-1]['files'][0]
  self.assertEqual(images[overlapping['path']],overlapping['postimageSHA256'])
  self.assertIs(self.manifest['releaseReady'],False)
 def test_overlap_preimage_chain_is_required(self):
  m=copy.deepcopy(self.manifest);m['patches'][-1]['files'][0]['preimageSHA256']='0'*64
  with self.assertRaises(ValueError):corrections.verify_manifest(ROOT,m)
 def test_dependency_and_order_are_explicit(self):
  m=copy.deepcopy(self.manifest);m['patches'][-1]['dependsOn']=[]
  with self.assertRaises(ValueError):corrections.verify_manifest(ROOT,m)
  m=copy.deepcopy(self.manifest);m['patches'][-2:]=list(reversed(m['patches'][-2:]))
  with self.assertRaises(ValueError):corrections.verify_manifest(ROOT,m)
 def test_cache_proof_cannot_be_rebound(self):
  with self.assertRaises(ValueError):corrections.verify_manifest(ROOT,{**self.manifest,'generatedBuildCacheEvidenceSHA256':'0'*64})
 def test_cumulative_delta_reconstructs_first_preimage(self):
  source={'kind':'file','path':cache.SOURCE,'sha256':cache.SOURCE_HASH,'sizeBytes':200,'mode':420}
  generated={'kind':'file','path':cache.CACHE,'sha256':cache.CACHE_HASH,'sizeBytes':2178,'mode':420}
  final={'kind':'file','path':'controlled.cc','sha256':'c'*64,'sizeBytes':12,'mode':420}
  full={'schemaVersion':1,'sourceFileCount':3,'deletedPathCount':0,'deletedPaths':[],'entries':sorted([source,generated,final],key=lambda e:e['path'])}
  before={'schemaVersion':1,'sourceFileCount':2,'deletedPathCount':0,'deletedPaths':[],'entries':sorted([source,{**final,'sha256':'a'*64,'sizeBytes':10}],key=lambda e:e['path'])}
  receipt={'generatedBuildCacheEvidenceSHA256':self.manifest['generatedBuildCacheEvidenceSHA256'],'appliedPatches':[{'files':[{'path':'controlled.cc','preimageSHA256':'a'*64,'postimageSHA256':'b'*64,'preimageSizeBytes':10,'mode':420}]},{'files':[{'path':'controlled.cc','preimageSHA256':'b'*64,'postimageSHA256':'c'*64,'preimageSizeBytes':11,'mode':420}]}]}
  semantic.verify_delta(full,compact_snapshot(full),receipt,compact_snapshot(before))
  broken=copy.deepcopy(receipt);broken['appliedPatches'][1]['files'][0]['preimageSHA256']='d'*64
  with self.assertRaises(ValueError):semantic.verify_delta(full,compact_snapshot(full),broken,compact_snapshot(before))
  extra=copy.deepcopy(full);extra['entries'].append({'kind':'file','path':'unreviewed.pyc','sha256':'e'*64,'sizeBytes':1,'mode':420});extra['entries'].sort(key=lambda e:e['path']);extra['sourceFileCount']+=1
  with self.assertRaises(ValueError):semantic.verify_delta(extra,compact_snapshot(extra),receipt,compact_snapshot(before))

if __name__=='__main__':unittest.main()
