"""Additive exact-source contracts; old M155 replay and signed bytes stay separate.

A source delta is checked against the frozen base aggregate, never reinterpreted
as a newly executed historical patch replay. Runtime qualification is separate.
"""
from __future__ import annotations
import copy,json
from pathlib import Path
import chromium_15540_release_evidence as base
import chromium_15540_semantic_corrections as corrections
from chromium_15540_source_snapshot import build_snapshot,compact_snapshot

BINDINGS=('semanticCorrectionSet','baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256','correctionsManifestSHA256','correctionsReceiptSHA256','sourceInputSnapshotSHA256')
def bindings_for(document):
 return BINDINGS+(('generatedBuildCacheEvidenceSHA256',) if 'generatedBuildCacheEvidenceSHA256' in document else ())
RECEIPT_KEYS={'schemaVersion','kind','semanticCorrectionSet','targetChromiumVersion','correctionsManifestSHA256','baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256','sourceInputSnapshotSHA256','appliedPatches','releaseReady'}

def prefix_for(document:dict)->str:
 value=document.get('semanticCorrectionSet')
 if not isinstance(value,str) or value not in corrections.VARIANTS:raise base.M15540EvidenceError('Unknown additive source variant')
 return corrections.VARIANTS[value][0]

def verify_receipt(project:Path,document:dict,receipt:dict)->dict:
 corrections.verify_manifest(project,document)
 prefix=prefix_for(document)
 expected_keys=RECEIPT_KEYS|({'generatedBuildCacheEvidenceSHA256'} if 'generatedBuildCacheEvidenceSHA256' in document else set())
 if set(receipt)!=expected_keys or type(receipt['schemaVersion']) is not int or receipt['schemaVersion']!=1 or receipt['kind']!='semantic-source-delta-receipt' or receipt['releaseReady'] is not False or receipt['targetChromiumVersion']!=base.VERSION:raise base.M15540EvidenceError('Invalid additive receipt schema')
 for key in ('semanticCorrectionSet','baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256'):
  if receipt.get(key)!=document[key]:raise base.M15540EvidenceError('Additive receipt base binding mismatch')
 if 'generatedBuildCacheEvidenceSHA256' in document and receipt.get('generatedBuildCacheEvidenceSHA256')!=document['generatedBuildCacheEvidenceSHA256']:raise base.M15540EvidenceError('Receipt cache dependency mismatch')
 if receipt['correctionsManifestSHA256']!=base.sha256_file(base.safe_relative_regular(project,f'runtime/{prefix}-corrections-manifest.json')):raise base.M15540EvidenceError('Additive receipt manifest binding mismatch')
 base.require_hash(receipt['sourceInputSnapshotSHA256'],'prebuild snapshot')
 if receipt['sourceInputSnapshotSHA256']!=corrections.REVIEWED_INPUT_SNAPSHOTS[document['semanticCorrectionSet']]:raise base.M15540EvidenceError('Unreviewed additive prebuild aggregate')
 items=receipt['appliedPatches']
 if not isinstance(items,list) or len(items)!=len(document['patches']):raise base.M15540EvidenceError('Incomplete additive receipt')
 for applied,patch in zip(items,document['patches']):
  if not isinstance(applied,dict) or set(applied)!={'vector','patchSHA256','files'} or applied['vector']!=patch['vector'] or applied['patchSHA256']!=patch['sha256'] or not isinstance(applied['files'],list) or len(applied['files'])!=len(patch['files']):raise base.M15540EvidenceError('Receipt patch order or digest mismatch')
  for observed,expected in zip(applied['files'],patch['files']):
   if not isinstance(observed,dict) or set(observed)!={'path','preimageSHA256','postimageSHA256','preimageSizeBytes','mode'} or any(observed[k]!=expected[k] for k in expected):raise base.M15540EvidenceError('Receipt file binding mismatch')
   if type(observed['preimageSizeBytes']) is not int or not 0<=observed['preimageSizeBytes']<=4*1024*1024 or type(observed['mode']) is not int or observed['mode'] not in (0o644,0o755):raise base.M15540EvidenceError('Receipt file metadata mismatch')
 base.reject_local_paths(receipt)
 return receipt

def verify_delta(full:dict,snapshot:dict,receipt:dict,base_snapshot:dict)->None:
 if compact_snapshot(full)!=snapshot:raise base.M15540EvidenceError('Corrected full inventory does not match prebuild snapshot')
 files={}
 for p in receipt['appliedPatches']:
  for f in p['files']:
   if f['path'] in files:
    prior=files[f['path']]
    if f['preimageSHA256']!=prior['postimageSHA256'] or f['mode']!=prior['mode']:raise base.M15540EvidenceError('Overlapping correction receipt lineage mismatch')
    files[f['path']]={**prior,'postimageSHA256':f['postimageSHA256']}
   else:files[f['path']]=f
 found=set();reconstructed=copy.deepcopy(full)
 if 'generatedBuildCacheEvidenceSHA256' in receipt:
  from chromium_15540_generated_cache import normalize,reviewed_document
  reconstructed=normalize(reconstructed,reviewed_document())
 for entry in reconstructed.get('entries',[]):
  if entry['path'] not in files:continue
  expected=files[entry['path']]
  if entry.get('kind')!='file' or entry.get('sha256')!=expected['postimageSHA256'] or entry.get('mode')!=expected['mode']:raise base.M15540EvidenceError('Additive postimage metadata differs')
  found.add(entry['path']);entry.update(sha256=expected['preimageSHA256'],sizeBytes=expected['preimageSizeBytes'])
 if found!=set(files) or compact_snapshot(reconstructed)!=base_snapshot:raise base.M15540EvidenceError('Source contains undeclared changes or unproven preimages')

def verify_contract(project:Path,variant:dict)->tuple[dict,dict,dict]:
 prefix=prefix_for(variant);runtime=project/'runtime';base_contract,base_snapshot=base.verify_contract(project)
 manifest=corrections.object_at(base.safe_relative_regular(runtime,prefix+'-corrections-manifest.json'));corrections.verify_manifest(project,manifest)
 if manifest['semanticCorrectionSet']!=variant['semanticCorrectionSet']:raise base.M15540EvidenceError('Manifest variant mismatch')
 receipt=corrections.object_at(base.safe_relative_regular(runtime,prefix+'-corrections-receipt.json'));verify_receipt(project,manifest,receipt)
 contract=corrections.object_at(base.safe_relative_regular(runtime,prefix+'-source-contract.json'))
 if type(contract.get('schemaVersion')) is not int or contract.get('schemaVersion')!=3 or contract.get('status')!='source-qualified' or contract.get('releaseReady') is not False:raise base.M15540EvidenceError('Unqualified additive source contract')
 expected=copy.deepcopy(base_contract);expected.update(schemaVersion=3,semanticCorrectionSet=manifest['semanticCorrectionSet'],baseSourceContractSHA256=manifest['baseSourceContractSHA256'],baseSourceSnapshotSHA256=manifest['baseSourceSnapshotSHA256'],baseOrderedReplaySHA256=manifest['baseOrderedReplaySHA256'],correctionsManifestSHA256=base.sha256_file(runtime/(prefix+'-corrections-manifest.json')),correctionsReceiptSHA256=base.sha256_file(runtime/(prefix+'-corrections-receipt.json')),sourceInputSnapshotSHA256=receipt['sourceInputSnapshotSHA256'],sourceSnapshotSHA256=base.sha256_file(runtime/(prefix+'-source-snapshot.json')),sourceInputManifestSHA256=base.sha256_file(runtime/(prefix+'-source-input-manifest.json')))
 generated=None
 if 'generatedBuildCacheEvidenceSHA256' in variant:
  from chromium_15540_generated_cache import verify_document,POST_SNAPSHOT_HASH
  if prefix not in ('chromium-15540-semantic-v3','chromium-15540-semantic-v4','chromium-15540-semantic-v5'):raise base.M15540EvidenceError('Unreviewed generated-cache variant')
  generated_path=base.safe_relative_regular(runtime,'chromium-15540-semantic-v3-generated-build-cache.json');generated=corrections.object_at(generated_path);verify_document(generated)
  digest=base.sha256_file(generated_path)
  required_snapshot=POST_SNAPSHOT_HASH if prefix=='chromium-15540-semantic-v3' else receipt['sourceInputSnapshotSHA256']
  if digest!=variant['generatedBuildCacheEvidenceSHA256'] or expected['sourceSnapshotSHA256']!=required_snapshot:raise base.M15540EvidenceError('Generated cache source binding mismatch')
  expected['generatedBuildCacheEvidenceSHA256']=digest
 if contract!=expected:raise base.M15540EvidenceError('Additive contract changed unrelated base policy or bindings')
 snapshot=base.read_object(base.safe_relative_regular(runtime,prefix+'-source-snapshot.json'),'additive snapshot')
 prebuild=base.safe_relative_regular(runtime,prefix+'-prebuild-source-snapshot.json')
 if base.sha256_file(prebuild)!=receipt['sourceInputSnapshotSHA256']:raise base.M15540EvidenceError('Reviewed prebuild snapshot changed')
 if generated is None and (base.read_object(prebuild,'additive prebuild snapshot')!=snapshot or contract['sourceSnapshotSHA256']!=receipt['sourceInputSnapshotSHA256']):raise base.M15540EvidenceError('Source changed after reviewed prebuild snapshot')
 for key in set(base_snapshot)-{'entriesSHA256','sourceFileCount'}:
  if snapshot.get(key)!=base_snapshot[key]:raise base.M15540EvidenceError('Unrelated source snapshot metadata changed')
 if snapshot.get('sourceFileCount')!=base_snapshot['sourceFileCount']+(1 if generated else 0):raise base.M15540EvidenceError('Unexpected generated input count')
 base.require_hash(snapshot.get('entriesSHA256'),'additive entries')
 inputs=base.read_object(base.safe_relative_regular(runtime,prefix+'-source-input-manifest.json'),'additive inputs')
 expected_inputs={k:contract[k] for k in bindings_for(contract)};expected_inputs.update(schemaVersion=1,chromiumVersion=base.VERSION,status='source-reconstructed',sourceInputsReady=True,releaseReady=False,sourceSnapshotSHA256=contract['sourceSnapshotSHA256'],buildArgsSHA256=contract['buildArgsSHA256'])
 if type(inputs.get('schemaVersion')) is not int or inputs.get('sourceInputsReady') is not True or inputs.get('releaseReady') is not False or inputs!=expected_inputs:raise base.M15540EvidenceError('Additive input manifest mismatch')
 return contract,snapshot,receipt

def verify_candidate_document(document:dict,*,project_root:Path,source_root:Path|None=None)->None:
 prefix=prefix_for(document);runtime=project_root/'runtime'
 canonical=base.read_object(base.safe_relative_regular(runtime,prefix+'-port-candidate.json'),'additive candidate')
 if document!=canonical:raise base.M15540EvidenceError('Candidate differs from exact additive evidence')
 contract,snapshot,receipt=verify_contract(project_root,document)
 expected={k:contract[k] for k in bindings_for(contract)};expected.update(schemaVersion=1,status='candidate-bound',releaseReady=False,targetChromiumVersion=base.VERSION,targetArchitecture='arm64',sourceContractSHA256=base.sha256_file(runtime/(prefix+'-source-contract.json')),sourceInputManifestSHA256=contract['sourceInputManifestSHA256'],sourceSnapshotSHA256=contract['sourceSnapshotSHA256'],binaryBinding=document.get('binaryBinding'),policy='Source and unsigned build only; signed runtime and release gates remain required.')
 if type(document.get('schemaVersion')) is not int or document.get('releaseReady') is not False or document!=expected:raise base.M15540EvidenceError('Additive candidate source binding mismatch')
 binding=document['binaryBinding'];keys={'status','sourceVersion','architecture','argsGNSHA256','candidateExecutableSHA256','candidateFrameworkSHA256'}
 if not isinstance(binding,dict) or set(binding)!=keys or (binding['status'],binding['sourceVersion'],binding['architecture'])!=('bound-to-built-candidate',base.VERSION,'arm64') or binding['argsGNSHA256']!=contract['buildArgsSHA256']:raise base.M15540EvidenceError('Additive binary binding mismatch')
 for key in ('argsGNSHA256','candidateExecutableSHA256','candidateFrameworkSHA256'):base.require_hash(binding[key],key)
 old=base.read_object(runtime/'chromium-15540-port-candidate.json','base candidate')['binaryBinding']
 if binding['candidateFrameworkSHA256']==old['candidateFrameworkSHA256']:raise base.M15540EvidenceError('Old runtime cannot inherit additive source qualification')
 base.reject_local_paths(document)
 if source_root is not None:
  full=build_snapshot(source_root,source_root/snapshot['argsGN']['relativePath'])
  if 'generatedBuildCacheEvidenceSHA256' in contract:
   from chromium_15540_generated_cache import normalize,verify_live
   generated=corrections.object_at(runtime/'chromium-15540-semantic-v3-generated-build-cache.json');verify_live(source_root,generated)
   if compact_snapshot(full)!=snapshot:raise base.M15540EvidenceError('Postbuild source differs from exact final inventory')
   if prefix=='chromium-15540-semantic-v3':full=normalize(full,generated)
   before=base.read_object(runtime/(prefix+'-prebuild-source-snapshot.json'),'prebuild snapshot')
  else:before=snapshot
  verify_delta(full,before,receipt,base.read_object(runtime/'chromium-15540-source-snapshot.json','base snapshot'))
  manifest=corrections.object_at(runtime/(prefix+'-corrections-manifest.json'));corrections.verify_live_postimages(project_root,source_root,manifest)
  external=base.read_object(runtime/'chromium-15540-source-evidence/pinned-build-inputs.json','base build inputs');base.verify_restored_build_types(external['restoredBuildTypes'],source_root)
  for item in external['inputs']:
   if base.sha256_file(base.safe_relative_regular(source_root,item['path']))!=item['sha256']:raise base.M15540EvidenceError('Pinned compiler input changed')

def verify_candidate_lock(lock:dict,*,provenance:dict,project_root:Path)->None:
 prefix=prefix_for(provenance);runtime=project_root/'runtime';verify_candidate_document(provenance,project_root=project_root)
 canonical=base.read_object(base.safe_relative_regular(runtime,'fingerprint-'+prefix+'.lock.json'),'additive lock')
 if type(lock.get('schemaVersion')) is not int or lock.get('releaseReady') is not False or lock!=canonical or prefix_for(lock)!=prefix:raise base.M15540EvidenceError('Additive lock variant, schema type or canonical mismatch')
 # Preserve all base licensing/upstream/build policy; replace only source bindings.
 old=base.read_object(runtime/'fingerprint-chromium-15540.lock.json','base lock');expected=copy.deepcopy(old)
 for key in bindings_for(provenance):expected[key]=provenance[key]
 expected.update(sourceContract='runtime/'+prefix+'-source-contract.json',sourceContractSHA256=provenance['sourceContractSHA256'],sourceProvenance='runtime/'+prefix+'-port-candidate.json',sourceProvenanceSHA256=base.sha256_file(runtime/(prefix+'-port-candidate.json')))
 expected['binaryBinding']={'requiredEvidence':expected['sourceProvenance'],'status':'bound-by-source-candidate-and-runtime-report'}
 expected['verification']={'coherentAppleDeviceTuples':'pending-runtime-evidence','scope':'Fresh signed runtime semantics, realms, route and release gates required; prior runtime PASS not inherited.'}
 if lock!=expected:raise base.M15540EvidenceError('Additive lock changed unrelated base or inherited runtime PASS')
 base.reject_local_paths(lock)
