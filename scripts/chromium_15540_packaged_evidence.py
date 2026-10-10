"""Copy/verify whitelisted M155 evidence including additive base dependencies."""
from pathlib import Path
import argparse,shutil
import chromium_15540_release_evidence as base
from chromium_15540_variant import reviewed_lock_prefix,verify_candidate_lock

def names(lock:dict)->list[str]:
 prefix=reviewed_lock_prefix(lock)
 result=['chromium-15540-source-contract.json','chromium-15540-source-input-manifest.json','chromium-15540-source-snapshot.json','chromium-15540-rebase-plan.json','chromium-15540-port-candidate.json','chromium-15540-toolchain-lock.json']
 result+=['chromium-15540-source-evidence/'+n for n in base.EVIDENCE_NAMES]
 if prefix!='chromium-15540':result+=[prefix+'-'+suffix+'.json' for suffix in ('source-contract','source-input-manifest','source-snapshot','port-candidate','prebuild-source-snapshot','corrections-manifest','corrections-receipt')]
 if 'generatedBuildCacheEvidenceSHA256' in lock:result.append('chromium-15540-semantic-v3-generated-build-cache.json')
 return result

def process(project:Path,evidence:Path,lock:dict,*,copy:bool=False)->None:
 prefix=reviewed_lock_prefix(lock);candidate=base.read_object(project/'runtime'/(prefix+'-port-candidate.json'),'M155 source candidate');verify_candidate_lock(lock,provenance=candidate,project_root=project)
 if evidence.is_symlink() or not evidence.is_dir():raise ValueError('Evidence root must be an existing regular directory')
 for relative in names(lock):
  src=base.safe_relative_regular(project/'runtime',relative);dst=evidence/relative
  if any(p.is_symlink() for p in (dst,*dst.parents) if p==evidence or p.is_relative_to(evidence)):raise ValueError('Packaged evidence crosses symlink')
  if copy:
   dst.parent.mkdir(parents=True,exist_ok=True)
   if not dst.exists():
    with src.open('rb') as i,dst.open('xb') as o:shutil.copyfileobj(i,o)
  if base.sha256_file(base.safe_relative_regular(evidence,relative))!=base.sha256_file(src):raise ValueError('Packaged source evidence differs: '+relative)

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('lock',type=Path);parser.add_argument('evidence',type=Path);parser.add_argument('--copy',action='store_true');a=parser.parse_args()
 try:process(Path(__file__).resolve().parents[1],a.evidence,base.read_object(a.lock,'M155 candidate lock'),copy=a.copy)
 except (OSError,ValueError) as e:parser.exit(1,'M155 packaged evidence rejected: '+str(e)+'\n')
