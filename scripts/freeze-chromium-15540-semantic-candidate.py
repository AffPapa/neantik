#!/usr/bin/env python3
"""Bind a corrected M155 build to reviewed prebuild bytes; never overwrite base."""
import argparse,copy,importlib.util,json,sys,plistlib
from pathlib import Path
import chromium_15540_release_evidence as base
import chromium_15540_semantic_corrections as corrections
import chromium_15540_semantic_release_evidence as semantic
from chromium_15540_source_snapshot import build_snapshot,compact_snapshot
PROJECT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('baseline_freezer',PROJECT/'scripts/freeze-chromium-15540-candidate.py');freeze=importlib.util.module_from_spec(spec);spec.loader.exec_module(freeze)

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('source',type=Path);parser.add_argument('args_gn',type=Path);parser.add_argument('unsigned_app',type=Path);parser.add_argument('--variant',required=True);args=parser.parse_args();created=[]
 try:
  prefix=semantic.prefix_for({'semanticCorrectionSet':args.variant});runtime=PROJECT/'runtime'
  if any(not p.is_absolute() or p.is_symlink() for p in (args.source,args.args_gn,args.unsigned_app)):raise ValueError('Absolute non-symlink source/build inputs required')
  names=[prefix+'-source-snapshot.json',prefix+'-source-input-manifest.json',prefix+'-source-contract.json',prefix+'-port-candidate.json','fingerprint-'+prefix+'.lock.json']
  if any((runtime/n).exists() or (runtime/n).is_symlink() for n in names):raise ValueError('Refuse to replace frozen candidate evidence')
  original,base_snapshot=base.verify_contract(PROJECT)
  manifest=corrections.object_at(runtime/(prefix+'-corrections-manifest.json'));receipt=corrections.object_at(runtime/(prefix+'-corrections-receipt.json'));semantic.verify_receipt(PROJECT,manifest,receipt);corrections.verify_live_postimages(PROJECT,args.source,manifest)
  prebuild=base.safe_relative_regular(runtime,prefix+'-prebuild-source-snapshot.json');snapshot=base.read_object(prebuild,'prebuild snapshot')
  if base.sha256_file(prebuild)!=receipt['sourceInputSnapshotSHA256'] or args.args_gn.resolve()!=(args.source/snapshot['argsGN']['relativePath']).resolve() or base.sha256_file(args.args_gn)!=original['buildArgsSHA256']:raise ValueError('Prebuild snapshot/build path or arguments changed')
  full=build_snapshot(args.source,args.args_gn);postbuild=snapshot;cache_path=runtime/(prefix+'-generated-build-cache.json');cache_digest=None
  if cache_path.exists():
   from chromium_15540_generated_cache import normalize,verify_live,POST_SNAPSHOT_HASH,snapshot_digest
   cache=corrections.object_at(cache_path);verify_live(args.source,cache);postbuild=compact_snapshot(full)
   if snapshot_digest(postbuild)!=POST_SNAPSHOT_HASH:raise ValueError('Unreviewed postbuild inventory')
   semantic.verify_delta(normalize(full,cache),snapshot,receipt,base_snapshot);cache_digest=base.sha256_file(cache_path)
  else:semantic.verify_delta(full,snapshot,receipt,base_snapshot)
  frozen_hash=base.sha256_file(prebuild) if cache_digest is None else POST_SNAPSHOT_HASH;freeze.write_new(runtime/names[0],postbuild,created)
  if base.sha256_file(runtime/names[0])!=frozen_hash:raise ValueError('Source changed between reviewed prebuild and final snapshot')
  bindings={k:receipt[k] for k in ('semanticCorrectionSet','baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256','correctionsManifestSHA256','sourceInputSnapshotSHA256')};bindings['correctionsReceiptSHA256']=base.sha256_file(runtime/(prefix+'-corrections-receipt.json'))
  if 'generatedBuildCacheEvidenceSHA256' in receipt:
   from chromium_15540_generated_cache import verify_live,reviewed_document
   verify_live(args.source,reviewed_document());bindings['generatedBuildCacheEvidenceSHA256']=receipt['generatedBuildCacheEvidenceSHA256']
  if cache_digest is not None:bindings['generatedBuildCacheEvidenceSHA256']=cache_digest
  inputs={**bindings,'schemaVersion':1,'chromiumVersion':base.VERSION,'status':'source-reconstructed','sourceInputsReady':True,'releaseReady':False,'sourceSnapshotSHA256':frozen_hash,'buildArgsSHA256':original['buildArgsSHA256']};freeze.write_new(runtime/names[1],inputs,created)
  contract={**original,**bindings,'schemaVersion':3,'sourceSnapshotSHA256':frozen_hash,'sourceInputManifestSHA256':base.sha256_file(runtime/names[1])};freeze.write_new(runtime/names[2],contract,created)
  semantic.verify_contract(PROJECT,bindings)
  app=args.unsigned_app;info=plistlib.loads((app/'Contents/Info.plist').read_bytes());exe_name=info.get('CFBundleExecutable')
  if info.get('CFBundleShortVersionString')!=base.VERSION or not isinstance(exe_name,str) or not exe_name or '/' in exe_name:raise ValueError('Unexpected unsigned app identity')
  exe=base.safe_relative_regular(app,'Contents/MacOS/'+exe_name);framework=base.safe_relative_regular(app,'Contents/Frameworks/NeAntik Browser Framework.framework/Versions/'+base.VERSION+'/NeAntik Browser Framework')
  candidate={**bindings,'schemaVersion':1,'status':'candidate-bound','releaseReady':False,'targetChromiumVersion':base.VERSION,'targetArchitecture':'arm64','sourceContractSHA256':base.sha256_file(runtime/names[2]),'sourceInputManifestSHA256':contract['sourceInputManifestSHA256'],'sourceSnapshotSHA256':frozen_hash,'binaryBinding':{'status':'bound-to-built-candidate','sourceVersion':base.VERSION,'architecture':'arm64','argsGNSHA256':original['buildArgsSHA256'],'candidateExecutableSHA256':base.sha256_file(exe),'candidateFrameworkSHA256':base.sha256_file(framework)},'policy':'Source and unsigned build only; signed runtime and release gates remain required.'};freeze.write_new(runtime/names[3],candidate,created)
  semantic.verify_candidate_document(candidate,project_root=PROJECT);base.verify_unsigned_binary_binding(app,args.args_gn,candidate)
  old=base.read_object(runtime/'fingerprint-chromium-15540.lock.json','base lock');lock=copy.deepcopy(old);lock.update(bindings,sourceContract='runtime/'+names[2],sourceContractSHA256=candidate['sourceContractSHA256'],sourceProvenance='runtime/'+names[3],sourceProvenanceSHA256=base.sha256_file(runtime/names[3]));lock['binaryBinding']={'requiredEvidence':lock['sourceProvenance'],'status':'bound-by-source-candidate-and-runtime-report'};lock['verification']={'coherentAppleDeviceTuples':'pending-runtime-evidence','scope':'Fresh signed runtime semantics, realms, route and release gates required; prior runtime PASS not inherited.'};freeze.write_new(runtime/names[4],lock,created);semantic.verify_candidate_lock(lock,provenance=candidate,project_root=PROJECT)
 except (OSError,ValueError,KeyError,TypeError) as e:
  for r in reversed(created):freeze.remove_owned(r)
  print('Additive candidate freeze failed: '+str(e),file=sys.stderr);return 1
 print('PASS: corrected source/build candidate frozen; headed signed/notary/release gates pending');return 0
if __name__=='__main__':raise SystemExit(main())
