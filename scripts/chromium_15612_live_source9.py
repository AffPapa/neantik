"""Exact attempt9 source observation; no running-build scan or qualification.

The original attempt4 and attempt5 modules/receipts stay immutable. Native COPY aliases are
explicitly accounted and every nested source/output ancestor is revalidated.
Sequential observation still requires exclusive source custody; it is not an
atomic filesystem snapshot. The caller must execute authenticated helper
buffers and bind a fresh producer before canonical binary/runtime qualification.
"""
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import types

import chromium_15612_generated_cache as cache
import chromium_15612_receipt_projection as projection
import chromium_15612_postbuild9 as postbuild
import chromium_15612_live_source as original
import chromium_15612_build_copy_links_v2 as copies

TOOLS = postbuild.TOOLS | {'chromium_15612_live_source9.py'}


def require_tools(hashes):
    cache.need(isinstance(hashes,dict) and set(hashes)==TOOLS,
               'Complete reviewed attempt9 observer closure required')
    postbuild.require_tool_bindings({name:hashes[name] for name in postbuild.TOOLS})
    directory=Path(__file__).absolute().parent
    raw=cache.read_source_file(directory,'chromium_15612_live_source9.py',1024*1024)
    cache.need(hashlib.sha256(raw).hexdigest()==hashes['chromium_15612_live_source9.py'],
               'Reviewed attempt9 observer changed')


def observe_tree(source: Path,full,copy_document):
    mapping=postbuild.require_copy_map(copy_document,full)
    observed=set()
    def file_record(parent,leaf,name,before,expected):
        if name not in mapping:
            return original.file_record(parent,leaf,name,before,expected)
        cache.need(name not in observed,'Native COPY source observed twice')
        raw, info=copies.read_known_copy_source(source,name,16*1024*1024,mapping[name])
        cache.need(original.identity(info)==original.identity(before),
                   'Native COPY source changed between traversal and read')
        result={'kind':'file','path':name,'mode':mapping[name]['mode'],
                'sizeBytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
        cache.need(result==expected,'Observed native COPY source bytes differ')
        observed.add(name)
        return result
    # Keep the reviewed traversal and all its directory/type/coverage controls.
    # Only an explicitly mapped source leaf uses the corrected COPY reader;
    # unknown hardlinks retain the original strict nlink1 refusal.
    namespace={**original.observe_tree.__globals__,'file_record':file_record,'postbuild':postbuild}
    observer=types.FunctionType(original.observe_tree.__code__,namespace)
    result=observer(source,full)
    cache.need(observed==mapping.keys(),'Native COPY map live coverage differs')
    result.update(explicitCopyGroupsObserved=len(observed),unknownHardlinksRejected=True)
    return result


def prepare(*,artifacts: Path,source: Path,terminal_name: str,terminal_sha256: str,
            final_name: str,final_sha256: str,compact_name: str,compact_sha256: str,
            copy_map_name: str,copy_map_sha256: str,tool_hashes):
    require_tools(tool_hashes)
    state=postbuild.bound_document(artifacts,terminal_name,terminal_sha256,64*1024)
    postbuild.require_terminal(state)  # BEFORE full inventory or source work.
    log=cache.read_source_file(artifacts,'m156-native-build-attempt-9.log',256*1024*1024)
    cache.need(len(log)==state['logBytes'] and hashlib.sha256(log).hexdigest()==state['logSHA256'],
               'Exact terminal attempt9 log differs')
    started=datetime.now(timezone.utc).isoformat()
    full=postbuild.bound_document(artifacts,final_name,final_sha256,512*1024*1024)
    compact=postbuild.bound_document(artifacts,compact_name,compact_sha256,64*1024)
    cache.need(postbuild.compact(full)==compact,'Fresh full/compact source bindings differ')
    copy_document=postbuild.bound_document(artifacts,copy_map_name,copy_map_sha256,16*1024*1024)
    original.git_identity(source,full)
    observation=observe_tree(source,full,copy_document)
    with original.anchored_root(source):
        args=cache.read_source_file(source,postbuild.ARGS_NAME,1024*1024)
        version=cache.read_source_file(source,'chrome/VERSION',1024).decode('ascii')
    values=dict(line.split('=',1) for line in version.splitlines() if '=' in line)
    cache.need('.'.join(values[key] for key in ('MAJOR','MINOR','BUILD','PATCH'))==cache.VERSION and
               hashlib.sha256(args).hexdigest()==postbuild.ARGS_SHA256,
               'Observed version or frozen args differ')
    original.git_identity(source,full)
    require_tools(tool_hashes)
    return {'schemaVersion':1,'status':'independently-observed-attempt9-source-only',
            'observerStartedAt':started,'observerFinishedAt':datetime.now(timezone.utc).isoformat(),
            'chromiumVersion':cache.VERSION,'officialChromiumBase':full['officialChromiumBase'],
            'terminalStateSHA256':terminal_sha256,'terminalLogSHA256':state['logSHA256'],
            'originalFreezeSHA256':postbuild.FREEZE_SHA256,'observedFullSHA256':final_sha256,
            'observedCompactSHA256':compact_sha256,'nativeCopyMapSHA256':copy_map_sha256,
            'deletedPathCount':len(full['deletedPaths']),'argsGN':full['argsGN'],
            'reviewedVerifierToolHashes':tool_hashes,**observation,
            'sourceExecution':False,'atomicFilesystemSnapshot':False,
            'exclusiveSourceCustodyRequired':True,'freshProducerLaunchBindingStillRequired':True,
            'binaryBindingVerified':False,'runtimeQualified':False,'releaseReady':False}
