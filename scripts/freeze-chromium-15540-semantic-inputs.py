#!/usr/bin/env python3
"""Freeze an additive prebuild input set without replacing the M155 baseline."""
import argparse,copy,importlib.util,json,sys
from pathlib import Path
import chromium_15540_release_evidence as base
import chromium_15540_semantic_corrections as corrections
import chromium_15540_semantic_release_evidence as semantic
from chromium_15540_source_snapshot import build_snapshot,compact_snapshot

PROJECT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('baseline_freezer',PROJECT/'scripts/freeze-chromium-15540-candidate.py');freeze=importlib.util.module_from_spec(spec);spec.loader.exec_module(freeze)

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('source',type=Path);parser.add_argument('manifest',type=Path);parser.add_argument('prebuild_snapshot',type=Path);parser.add_argument('full_inventory',type=Path);parser.add_argument('preimages',type=Path);args=parser.parse_args();created=[]
 try:
  if any(not p.is_absolute() or p.is_symlink() for p in vars(args).values()):raise ValueError('Absolute non-symlink inputs required')
  base_contract,old_snapshot=base.verify_contract(PROJECT);manifest=corrections.object_at(args.manifest);prefix=semantic.prefix_for(manifest)
  if args.manifest!=PROJECT/'runtime'/(prefix+'-corrections-manifest.json'):raise ValueError('Only exact reviewed correction path accepted')
  corrections.verify_live_postimages(PROJECT,args.source,manifest)
  snapshot=base.read_object(args.prebuild_snapshot,'prebuild snapshot');full=base.read_object(args.full_inventory,'full source inventory')
  entries={e['path']:e for e in full['entries']};applied=[]
  for patch in manifest['patches']:
   files=[]
   for item in patch['files']:
    relative=patch['vector']+'/'+item['path'] if (args.preimages/patch['vector']).exists() else item['path']
    pre=base.safe_relative_regular(args.preimages,relative);stat=pre.stat()
    if base.sha256_file(pre)!=item['preimageSHA256']:raise ValueError('Preserved source preimage hash mismatch')
    files.append({**item,'preimageSizeBytes':stat.st_size,'mode':entries[item['path']]['mode']})
   applied.append({'vector':patch['vector'],'patchSHA256':patch['sha256'],'files':files})
  receipt={k:manifest[k] for k in ('semanticCorrectionSet','baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256')};receipt.update(schemaVersion=1,kind='semantic-source-delta-receipt',targetChromiumVersion=base.VERSION,correctionsManifestSHA256=base.sha256_file(args.manifest),sourceInputSnapshotSHA256=base.sha256_file(args.prebuild_snapshot),appliedPatches=applied,releaseReady=False)
  if 'generatedBuildCacheEvidenceSHA256' in manifest:
   from chromium_15540_generated_cache import verify_live,reviewed_document
   verify_live(args.source,reviewed_document());receipt['generatedBuildCacheEvidenceSHA256']=manifest['generatedBuildCacheEvidenceSHA256']
  semantic.verify_receipt(PROJECT,manifest,receipt);semantic.verify_delta(full,snapshot,receipt,old_snapshot)
  current_args=base.safe_relative_regular(args.source,snapshot['argsGN']['relativePath'])
  if base.sha256_file(current_args)!=base_contract['buildArgsSHA256']:raise ValueError('Build arguments changed')
  # Saved inventories prove a delta; only a fresh scan proves the live build inputs.
  semantic.verify_delta(build_snapshot(args.source,current_args),snapshot,receipt,old_snapshot)
  freeze.write_new(PROJECT/'runtime'/(prefix+'-prebuild-source-snapshot.json'),snapshot,created)
  if base.sha256_file(PROJECT/'runtime'/(prefix+'-prebuild-source-snapshot.json'))!=receipt['sourceInputSnapshotSHA256']:raise ValueError('Prebuild JSON encoding changed')
  freeze.write_new(PROJECT/'runtime'/(prefix+'-corrections-receipt.json'),receipt,created)
 except (OSError,ValueError,KeyError,TypeError) as e:
  for r in reversed(created):freeze.remove_owned(r)
  print('Additive input freeze failed: '+str(e),file=sys.stderr);return 1
 print('PASS: exact additive inputs frozen; build/runtime/release qualification still required');return 0
if __name__=='__main__':raise SystemExit(main())
