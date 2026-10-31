#!/usr/bin/env python3
"""Prove the postbuild M156 source delta after the single native build exits.

Produces a private source-only receipt. It never starts a build, creates a
release contract, signs a binary, or claims runtime qualification. Full source
inventories are authenticated before parsing; current source-derived caches
are checked individually rather than excluded by a glob.
"""
from __future__ import annotations
import argparse
import errno
import hashlib
import json
import os
import sys
import subprocess
import chromium_15612_generated_cache as cache_module
import chromium_15612_receipt_projection as projection_module
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from chromium_15612_generated_cache import (
    COMMIT, TREE, VERSION, HASH, M156CacheError, compare_inventories,
    inventory, need, read_source_file, relative_path, verify_cache,
)

FREEZE_SHA256 = '3593e29cb4eaaed98b0fa7b97a5e0c7710328d8b2e9da6482c5491307eb62c48'
FULL_SHA256 = 'fb315fbe7d1bd2b1e8cb31ba9eef023ed8a9cd057c520f5800067e7a226c0d2e'
COMPACT_SHA256 = 'f535b711dbf3e2f505cdd5acd00c9fddca286c254154fc33b27dd75fdc8cd800'
ALGORITHM_SHA256 = '2242e81e73000bdd6f4e7e9a4a5f65ea1fd4ced4b77b298118a5e34d88394496'
ARGS_SHA256 = 'b32623308042c6b3b86f14ce9635ccc9abdc290148ce596c1e4f4a43ffde9a01'
ARGS_NAME = 'out/NeAntikM156Qualified20261009/args.gn'


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical_digest(value: Any) -> str:
    result = hashlib.sha256()
    for chunk in json.JSONEncoder(sort_keys=True,separators=(',',':'),ensure_ascii=True).iterencode(value):
        result.update(chunk.encode('utf8'))
    return result.hexdigest()


def bound_document(root: Path, name: str, expected: str, maximum: int) -> dict[str, Any]:
    need(isinstance(expected,str) and HASH.fullmatch(expected) is not None, 'Pinned input digest required')
    raw = read_source_file(root,relative_path(name),maximum)
    need(digest(raw) == expected, 'Pinned postbuild input digest mismatch')
    def unique(pairs):
        result={}
        for key,value in pairs:
            need(key not in result,'Duplicate JSON input key')
            result[key]=value
        return result
    value = json.loads(raw,object_pairs_hook=unique)
    need(isinstance(value,dict), 'Postbuild input must be an object')
    return value


def timestamp(value: Any) -> datetime:
    need(isinstance(value,str) and 0 < len(value) <= 64, 'Timestamp required')
    try:
        result = datetime.fromisoformat(value)
    except ValueError as error:
        raise M156CacheError('Invalid build timestamp') from error
    need(result.tzinfo is not None and result.utcoffset() is not None, 'Timezone required')
    return result


def require_terminal(state: dict[str, Any]) -> None:
    keys={'schemaVersion','status','startedAt','contractSHA256','argsSHA256','jobs','targets',
          'sourceInputsFrozen','releaseReady','ownerPID','ninjaPID','lastResourceSampleAt','logBytes',
          'exitCode','finishedAt','logSHA256'}
    need(isinstance(state,dict) and set(state)==keys and type(state['schemaVersion']) is int and
         state['schemaVersion']==1 and state['status']=='native-build-completed-needs-binary-and-runtime-qualification' and
         type(state['exitCode']) is int and state['exitCode']==0 and state['releaseReady'] is False and
         state['sourceInputsFrozen'] is True and type(state['jobs']) is int and state['jobs']==2 and
         state['targets']==['chrome','chromedriver'] and state['contractSHA256']==FREEZE_SHA256 and
         state['argsSHA256']==ARGS_SHA256,'Exact successful terminal native build required')
    need(type(state['logBytes']) is int and state['logBytes']>=0 and
         isinstance(state['logSHA256'],str) and HASH.fullmatch(state['logSHA256']) is not None,
         'Terminal build log binding missing')
    start,finish=timestamp(state['startedAt']),timestamp(state['finishedAt'])
    sample=timestamp(state['lastResourceSampleAt'])
    need(start<=sample<=finish<=datetime.now(timezone.utc),'Terminal build time order invalid')
    for field in ('ownerPID','ninjaPID'):
        need(type(state[field]) is int and 1 < state[field] < 2**31,'Invalid owned build PID')
    try:
        os.kill(state['ninjaPID'],0)  # Observation only; never signal/stop it.
    except OSError as error:
        need(error.errno==errno.ESRCH,'Cannot prove native process is gone')
    else:
        raise M156CacheError('Native PID still exists; terminal source scan refused')


def compact(full: dict[str, Any]) -> dict[str, Any]:
    need(set(full)=={'schemaVersion','recordType','targetChromiumVersion','officialChromiumBase','argsGN','sourceFileCount','deletedPathCount','entries','deletedPaths','releaseReady','provenanceLimit'},'Unexpected inventory fields')
    inventory(full)
    need(full['sourceFileCount']>=1_000_000 and full['deletedPathCount']==3248,
         'Full M156 inventory coverage insufficient')
    need(full['argsGN']=={'relativePath':ARGS_NAME,'sha256':ARGS_SHA256},'Exact M156 args missing')
    result={k:v for k,v in full.items() if k not in {'entries','deletedPaths'}}
    result.update(schemaVersion=2,inventoryDigestAlgorithm='sha256-canonical-json-v1',
                  entriesSHA256=canonical_digest(full['entries']),
                  deletedPathsSHA256=canonical_digest(full['deletedPaths']))
    return result


def require_tool_bindings(expected: dict[str,str]) -> None:
    names={'chromium_15612_postbuild.py','chromium_15612_generated_cache.py',
           'chromium_15612_receipt_projection.py'}
    need(isinstance(expected,dict) and set(expected)==names,'Reviewed verifier tool set required')
    directory=Path(__file__).resolve().parent
    need(Path(cache_module.__file__).resolve()==directory/'chromium_15612_generated_cache.py' and
         Path(projection_module.__file__).resolve()==directory/'chromium_15612_receipt_projection.py',
         'Loaded verifier module location differs')
    for name,sha in expected.items():
        need(isinstance(sha,str) and HASH.fullmatch(sha) is not None and
             digest(read_source_file(directory,name,1024*1024))==sha,
             'Reviewed verifier source changed')


def prepare(*,artifacts: Path,source: Path,terminal_name: str,terminal_sha256: str,
            final_name: str,final_sha256: str,python: Path,python_sha256: str,
            tool_hashes: dict[str,str]) -> dict[str,Any]:
    require_tool_bindings(tool_hashes)
    # Gate BEFORE any million-file inventory parsing or source scan.
    state=bound_document(artifacts,terminal_name,terminal_sha256,64*1024)
    require_terminal(state)
    log=read_source_file(artifacts,'m156-native-build-attempt-4.log',256*1024*1024)
    need(state['logBytes']<=len(log) and digest(log)==state['logSHA256'],'Completed build log changed')
    freeze=bound_document(artifacts,'m156-prebuild-attempt-4-contract.json',FREEZE_SHA256,1024*1024)
    need((freeze['chromiumVersion'],freeze['officialCommit'],freeze['officialTree'])==(VERSION,COMMIT,TREE) and
         freeze['inventoryAlgorithmSHA256']==ALGORITHM_SHA256 and freeze['sourceSnapshotSHA256']==FULL_SHA256 and
         freeze['compactSnapshotSHA256']==COMPACT_SHA256 and freeze['argsGN']==ARGS_SHA256,
         'Frozen M156 inputs differ')
    algorithm=read_source_file(artifacts,'m156_source_snapshot_inventory.py',1024*1024)
    need(digest(algorithm)==ALGORITHM_SHA256,'Frozen inventory algorithm changed')
    before=bound_document(artifacts,'m156-prebuild-attempt-4-source-snapshot.json',FULL_SHA256,512*1024*1024)
    expected_compact=bound_document(artifacts,'m156-prebuild-attempt-4-source-snapshot-compact.json',COMPACT_SHA256,64*1024)
    need(compact(before)==expected_compact,'Frozen full and compact inventories disagree')
    after=bound_document(artifacts,final_name,final_sha256,512*1024*1024)
    final_compact=compact(after)
    need(timestamp(state['finishedAt'])<=datetime.now(timezone.utc),'Build completion time invalid')
    caches=compare_inventories(before,after)
    need(len(caches)<=10_000,'Generated-cache delta limit exceeded')
    # Hash the exact live args and six native tools separately; source
    # inventory records cannot stand in for current tool bytes.
    need(digest(read_source_file(source,ARGS_NAME,1024*1024))==ARGS_SHA256,'Live build args changed')
    for name,expected in freeze['nativeToolHashes'].items():
        # Tool directories may be the intentionally pinned external payloads.
        # Resolve only this closed, digest-bound six-tool set, then read the
        # real target through the same no-follow descriptor reader. The full
        # external package/library closure remains a separate toolchain gate.
        target=(source/relative_path(name)).resolve(strict=True)
        need(digest(read_source_file(target.parent,target.name,512*1024*1024))==expected,
             'Live native tool changed')
    for record in caches:
        verify_cache(source,record,python,python_sha256=python_sha256)
    require_tool_bindings(tool_hashes)
    return {'schemaVersion':1,'status':'postbuild-source-delta-verified-only',
            'at':datetime.now(timezone.utc).isoformat(),'chromiumVersion':VERSION,
            'officialChromiumBase':{'commit':COMMIT,'tree':TREE},
            'originalFreezeSHA256':FREEZE_SHA256,'terminalStateSHA256':terminal_sha256,
            'terminalLogSHA256':state['logSHA256'],'prebuildFullSHA256':FULL_SHA256,
            'postbuildFullSHA256':final_sha256,'inventoryAlgorithmSHA256':ALGORITHM_SHA256,
            'prebuildCompact':expected_compact,'postbuildCompact':final_compact,
            'onlyDerivedCachesChanged':True,'sourceExecution':False,'generatedCaches':caches,
            'referencePythonSHA256':python_sha256,'nativeToolHashes':freeze['nativeToolHashes'],
            'reviewedVerifierToolHashes':dict(tool_hashes),
            'freshSnapshotProducerReceiptStillRequired':True,'verifierLaunchBindingStillRequired':True,'externalToolPackageClosureStillRequired':True,'binaryBindingVerified':False,
            'runtimeQualified':False,'releaseReady':False}


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('artifacts','source','terminal-name','terminal-sha256','final-name','final-sha256','python','python-sha256','verifier-sha256','cache-verifier-sha256','projection-verifier-sha256','output'):
        parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    report=prepare(artifacts=Path(args.artifacts),source=Path(args.source),terminal_name=args.terminal_name,
                   terminal_sha256=args.terminal_sha256,final_name=args.final_name,final_sha256=args.final_sha256,
                   python=Path(args.python),python_sha256=args.python_sha256,
                   tool_hashes={'chromium_15612_postbuild.py':args.verifier_sha256,
                                'chromium_15612_generated_cache.py':args.cache_verifier_sha256,
                                'chromium_15612_receipt_projection.py':args.projection_verifier_sha256})
    output=Path(args.output)
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as stream:json.dump(report,stream,indent=2);stream.write('\n')
    print('M156 source delta verified; binary/runtime/release qualification remains open')


if __name__=='__main__':
    try:
        main()
    except (M156CacheError,OSError,ValueError,subprocess.SubprocessError):
        sys.stderr.write('M156 postbuild proof refused; no qualification was produced.\n')
        raise SystemExit(1) from None
