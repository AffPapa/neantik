"""Explicit M155 candidate dispatch. Unknown or stripped variants fail closed."""
from pathlib import Path
import chromium_15540_release_evidence as legacy
import chromium_15540_semantic_release_evidence as semantic

def prefix_for(document:dict)->str:
 if 'semanticCorrectionSet' not in document:return legacy.PREFIX
 return semantic.prefix_for(document)

def verify_candidate_document(document:dict,*,project_root:Path,source_root:Path|None=None)->None:
 subject=legacy if prefix_for(document)==legacy.PREFIX else semantic
 subject.verify_candidate_document(document,project_root=project_root,source_root=source_root)

def verify_candidate_lock(lock:dict,*,provenance:dict,project_root:Path)->None:
 if prefix_for(lock)!=prefix_for(provenance):raise legacy.M15540EvidenceError('Mismatched M155 lock/candidate variants')
 subject=legacy if prefix_for(provenance)==legacy.PREFIX else semantic
 subject.verify_candidate_lock(lock,provenance=provenance,project_root=project_root)

def reviewed_lock_prefix(lock:dict)->str:
 prefix=prefix_for(lock)
 if lock.get('sourceContract')!='runtime/'+prefix+'-source-contract.json' or lock.get('sourceProvenance')!='runtime/'+prefix+'-port-candidate.json':raise legacy.M15540EvidenceError('Lock paths do not match explicit variant')
 return prefix

if __name__=='__main__':
 import argparse,sys
 parser=argparse.ArgumentParser();parser.add_argument('lock',type=Path);args=parser.parse_args()
 try:print(reviewed_lock_prefix(legacy.read_object(args.lock,'M155 variant lock')))
 except (OSError,ValueError) as e:parser.exit(1,'M155 variant rejected: '+str(e)+'\n')
