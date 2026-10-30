#!/usr/bin/env python3
"""Read-only official M156 Clang/Rust origin and payload verification.

No extraction, fetching, execution or native build. These observations must
be rebound to the final source snapshot and completed build separately.
"""
from __future__ import annotations
import ast
import hashlib
import os
import posixpath
import stat
import tarfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from chromium_15612_generated_cache import VERSION,COMMIT,TREE,need,relative_path,read_source_file
from chromium_15612_input_lineage import DEPS_SHA256
from chromium_15612_receipt_projection import strict_json
from chromium_15612_supplemental import PACKAGES,verify_secondary_bundle,write_new_store

MANIFEST_PINS={
 'clang-archive-inspection.json':'b0fc423896ff465dbaaa2ce3a8f750e40a961a1a2bfd8408a53cc8f40d061ea9',
 'rust-archive-inspection.json':'e3701718358666a51f0df04c2244145575150332221f2d056f15e0c005d4c854',
 'clang-payload-sha256.json':'a2db1c1021f436f85c2fbcfdf5b5feed7951f2fd779042fca4b775717e59fd67',
 'rust-payload-sha256.json':'12a948493d6d49112d1c853efcf9e3506fe5e86db7b82bc9fe05a07cbb6880f9',
}
DEPS_KEYS={'clang':'src/third_party/llvm-build/Release+Asserts','rust':'src/third_party/rust-toolchain'}
GENERATION={'clang':1790402697155562,'rust':1789143391575553}
SOURCE_PREFIX={'clang':'third_party/llvm-build/Release+Asserts','rust':'third_party/rust-toolchain'}
TOOL_PACKAGES={**PACKAGES,'llvmobjdump':{
 'url':'https://commondatastorage.googleapis.com/chromium-browser-clang/Mac_arm64/llvmobjdump-llvmorg-24-init-7747-g62397f8b-53.tar.xz',
 'archiveSHA256':'f93f89580341f51b80c713776a2f9645f090a971d82e459abbcc11fdd21b2ae4','size':5202064,'files':6}}
DEPS_KEYS['llvmobjdump']=DEPS_KEYS['clang'];GENERATION['llvmobjdump']=1790402697359142
SOURCE_PREFIX['llvmobjdump']=SOURCE_PREFIX['clang']
DANGLING_COMPATIBILITY_LINKS={
 'lib/clang/24/lib/aarch64-cros-linux-gnu':'aarch64-unknown-linux-gnu',
 'lib/clang/24/lib/armv7a-cros-linux-gnueabihf':'armv7-unknown-linux-gnueabihf',
 'lib/clang/24/lib/x86_64-cros-linux-gnu':'x86_64-unknown-linux-gnu',
}
PROBE_LOGS={'clang':'c45899f1786e41ada13f803e6f0836676b9bfbbd741a5c9312fc8ffd4ba2bdbe',
            'rustc':'de6863dac1b2ed4da06b4489bfc8187b8fc3458b7ea6c5919b5da61ab8c61d6f',
            'crubit':'fe779053abcc7b03ecd2c48f8152cc4d01e399cce3a0158a5fea3c210e74e68e'}


def literal(node:ast.AST,depth:int=0) -> Any:
    need(depth<=32,'DEPS selected literal nesting exceeds bound')
    if isinstance(node,ast.Constant):
        need(type(node.value) in {str,int},'Nonliteral DEPS package field')
        return node.value
    if isinstance(node,ast.List):
        need(len(node.elts)<=128,'DEPS package list exceeds bound')
        return [literal(value,depth+1) for value in node.elts]
    if isinstance(node,ast.Dict):
        need(len(node.keys)<=128,'DEPS package dictionary exceeds bound')
        result={}
        for key,value in zip(node.keys,node.values,strict=True):
            need(isinstance(key,ast.Constant) and type(key.value) is str and key.value not in result,
                 'Duplicate or nonliteral DEPS package key')
            result[key.value]=literal(value,depth+1)
        return result
    need(False,'Executable DEPS package expression refused')


def deps_packages(raw:bytes) -> dict[str,dict[str,Any]]:
    """Select exact ARM64 packages; do not execute DEPS or search comments."""
    need(len(raw)<=512*1024,'DEPS input exceeds bound')
    tree=ast.parse(raw.decode('utf8'))
    assignments=[node for node in tree.body if isinstance(node,ast.Assign) and
                 any(isinstance(t,ast.Name) and t.id=='deps' for t in node.targets)]
    need(len(assignments)==1 and len(assignments[0].targets)==1 and isinstance(assignments[0].value,ast.Dict),
         'Exactly one literal deps dictionary required')
    top=assignments[0].value;selected={};seen=set()
    for key,value in zip(top.keys,top.values,strict=True):
        # Values of unrelated entries may use Var. Dynamic keys/unpacking
        # could override an earlier valid section, so all keys are literal.
        need(isinstance(key,ast.Constant) and type(key.value) is str,'Dynamic DEPS key or unpacking refused')
        need(key.value not in seen,'Duplicate DEPS dependency key');seen.add(key.value)
        if key.value in DEPS_KEYS.values():selected[key.value]=literal(value)
    need(set(selected)==set(DEPS_KEYS.values()),'Official tool dependencies missing')
    result={}
    for kind,key in DEPS_KEYS.items():
        dep=selected[key];expected=TOOL_PACKAGES[kind];object_name=expected['url'].split('/chromium-browser-clang/',1)[1]
        need(isinstance(dep,dict) and set(dep)=={'dep_type','bucket','condition','objects'} and
             dep['dep_type']=='gcs' and dep['bucket']=='chromium-browser-clang' and
             dep['condition']=='not '+('rust' if kind=='rust' else 'llvm')+'_force_head_revision' and
             isinstance(dep['objects'],list),'Official tool dependency section mismatch')
        matched=[obj for obj in dep['objects'] if isinstance(obj,dict) and obj.get('object_name')==object_name]
        need(len(matched)==1,'Exact ARM64 tool object missing or duplicated')
        obj=matched[0]
        need(set(obj)=={'object_name','sha256sum','size_bytes','generation','condition'} and
             obj['condition']=='host_os == "mac" and host_cpu == "arm64"' and
             obj['sha256sum']==expected['archiveSHA256'] and type(obj['size_bytes']) is int and
             obj['size_bytes']==expected['size'] and type(obj['generation']) is int and
             obj['generation']==GENERATION[kind],'Official ARM64 tool object tuple mismatch')
        result[kind]={'dependency':key,'objectName':object_name,'url':expected['url'],
                      'sha256':obj['sha256sum'],'size':obj['size_bytes'],'DEPSGeneration':obj['generation'],
                      'serverGenerationObserved':False}
    return result


def metadata(inspection:dict[str,Any],payload:dict[str,str],expected:dict[str,Any]) -> dict[str,dict[str,Any]]:
    need(isinstance(inspection,dict) and set(inspection)=={'url','sha256','size','members'} and
         inspection['url']==expected['url'] and inspection['sha256']==expected['archiveSHA256'] and
         type(inspection['size']) is int and inspection['size']==expected['size'] and
         isinstance(inspection['members'],list) and 0<len(inspection['members'])<=10000 and
         isinstance(payload,dict),'Tool archive metadata invalid')
    members={};total=0
    for m in inspection['members']:
        need(isinstance(m,dict) and set(m)=={'path','kind','size','mode','link'},'Tool member fields invalid')
        name=relative_path(m['path']);need(name not in members,'Duplicate tool archive member')
        need(isinstance(m['kind'],str) and m['kind'] in {'file','directory','symlink'} and
             isinstance(m['mode'],str) and m['mode'] in {'0o644','0o755'} and
             type(m['size']) is int and 0<=m['size']<=1024**3,'Unsupported tool member')
        total+=m['size'];need(total<=8*1024**3,'Tool unpacked bytes exceed bound')
        if m['kind']=='file':
            need(m['link'] is None,'File member has link target')
        elif m['kind']=='directory':
            need(m['size']==0 and m['link'] is None and m['mode']=='0o755','Invalid tool directory')
        else:
            need(m['size']==0 and isinstance(m['link'],str) and 0<len(m['link'])<=4096 and
                 not m['link'].startswith('/') and '\\' not in m['link'] and '\0' not in m['link'],
                 'Unsafe tool symlink')
        members[name]=m
    from chromium_15612_input_lineage import is_hash
    need(set(payload)=={name for name,m in members.items() if m['kind']=='file'} and
         len(payload)==expected['files'] and all(is_hash(h) for h in payload.values()),'Tool payload coverage invalid')
    for name,m in members.items():
        for parent in Path(name).parents:
            if str(parent)=='.':continue
            need(str(parent) in members and members[str(parent)]['kind']=='directory','Tool archive traverses a non-directory')
        if m['kind']=='symlink':
            target=posixpath.normpath(posixpath.join(posixpath.dirname(name),m['link']))
            relative_path(target)
            # Official Mac packages include compatibility aliases whose
            # Linux runtime target is absent. Exact pinned target text and
            # lexical confinement are required; presence is not implied.
            need((target in members and members[target]['kind'] in {'file','directory'}) or
                 DANGLING_COMPATIBILITY_LINKS.get(name)==m['link'],'Tool link is dangling or chained')
    return members


def identity(s:os.stat_result) -> tuple[int,...]:
    return s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns


@contextmanager
def directory_anchor(root:Path,prefix:str=''):
    """Hold each directory below a trusted source root; reject replacement."""
    need(root.is_absolute() and not root.is_symlink(),'Real tool verification root required')
    parts=relative_path(prefix).split('/') if prefix else []
    fds=[os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)];anchors=[]
    try:
        original=os.fstat(fds[0])
        for part in parts:
            child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fds[-1])
            fds.append(child);anchors.append((fds[-2],part,os.fstat(child)))
        yield fds[-1]
        current=os.stat(root,follow_symlinks=False)
        need(stat.S_ISDIR(current.st_mode) and (current.st_dev,current.st_ino)==(original.st_dev,original.st_ino),
             'Trusted source root replaced')
        for parent,name,opened in anchors:
            current=os.stat(name,dir_fd=parent,follow_symlinks=False)
            need(stat.S_ISDIR(current.st_mode) and (current.st_dev,current.st_ino)==(opened.st_dev,opened.st_ino),
                 'Intermediate source directory replaced')
    finally:
        for fd in reversed(fds):os.close(fd)


@contextmanager
def held_file(root:Path,name:str,maximum:int):
    """No-follow ancestors, bounded regular file and stable descriptor."""
    parts=relative_path(name).split('/')
    with directory_anchor(root,'/'.join(parts[:-1])) as fd_dir:
        fd=os.open(parts[-1],os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW,dir_fd=fd_dir)
        try:
            before=os.fstat(fd)
            need(stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_nlink==1 and
                 0<=before.st_size<=maximum,'Tool input is not a bounded owned regular file')
            with os.fdopen(os.dup(fd),'rb') as stream:yield stream,before
            current=os.stat(parts[-1],dir_fd=fd_dir,follow_symlinks=False)
            need(stat.S_ISREG(current.st_mode) and identity(before)==identity(os.fstat(fd))==identity(current),
                 'Tool input changed during verification')
        finally:os.close(fd)


def stream_hash(stream,expected_size:int) -> str:
    digest=hashlib.sha256();remaining=expected_size
    while remaining:
        chunk=stream.read(min(1024*1024,remaining))
        need(bool(chunk),'Truncated tool input');digest.update(chunk);remaining-=len(chunk)
    need(not stream.read(1),'Tool input grew beyond bound')
    return digest.hexdigest()


def verify_archive(root:Path,name:str,inspection:dict[str,Any],payload:dict[str,str],expected:dict[str,Any]) -> None:
    metadata(inspection,payload,expected)
    with held_file(root,name,expected['size']) as (stream,observed):
        need(observed.st_size==expected['size'] and stream_hash(stream,observed.st_size)==expected['archiveSHA256'],
             'Official tool archive bytes mismatch')
        stream.seek(0);index=0
        with tarfile.open(fileobj=stream,mode='r|xz') as archive:
            for member in archive:
                need(index<len(inspection['members']),'Unexpected extra archive member')
                record={'path':posixpath.normpath(member.name),
                        'kind':'file' if member.isfile() else 'directory' if member.isdir() else 'symlink' if member.issym() else 'unsupported',
                        'size':member.size,'mode':oct(member.mode),'link':member.linkname if member.issym() else None}
                need(record==inspection['members'][index],'Archive differs from inspected member metadata');index+=1
                if member.isfile():
                    content=archive.extractfile(member);need(content is not None,'Tool archive content missing')
                    with content:need(stream_hash(content,member.size)==payload[record['path']],'Tool archived payload digest mismatch')
            need(index==len(inspection['members']),'Tool archive missing inspected member')


def observe_verified_archive(root:Path,name:str,expected:dict[str,Any]) -> tuple[dict[str,Any],dict[str,str]]:
    """Derive additive llvmobjdump metadata only after its DEPS hash matches."""
    inspected=[];payload={};total=0
    with held_file(root,name,expected['size']) as (stream,observed):
        need(observed.st_size==expected['size'] and stream_hash(stream,observed.st_size)==expected['archiveSHA256'],
             'Official additive tool archive bytes mismatch')
        stream.seek(0)
        with tarfile.open(fileobj=stream,mode='r|xz') as archive:
            for member in archive:
                need(len(inspected)<10000 and 0<=member.size<=1024**3,'Additive tool archive member exceeds bound')
                total+=member.size;need(total<=8*1024**3,'Additive tool archive total exceeds bound')
                name=relative_path(posixpath.normpath(member.name))
                kind='file' if member.isfile() else 'directory' if member.isdir() else 'symlink' if member.issym() else 'unsupported'
                inspected.append({'path':name,'kind':kind,'size':member.size,'mode':oct(member.mode),
                                  'link':member.linkname if member.issym() else None})
                if member.isfile():
                    content=archive.extractfile(member);need(content is not None,'Additive tool file missing')
                    with content:payload[name]=stream_hash(content,member.size)
    inspection={'url':expected['url'],'sha256':expected['archiveSHA256'],'size':expected['size'],'members':inspected}
    metadata(inspection,payload,expected)
    return inspection,payload


def cached_name(expected:dict[str,Any]) -> str:
    return '.'+expected['url'].split('/chromium-browser-clang/',1)[1].replace('/','_')


def downloader_metadata(root:Path,inspection:dict[str,Any],expected:dict[str,Any],source_prefix:str='') -> tuple[dict[str,dict[str,Any]],dict[str,str]]:
    """Allow only exact official cached object and three bound GCS markers."""
    archive=cached_name(expected);prefix=archive.replace('.tar.xz','_tar_xz')
    records={archive:{'path':archive,'kind':'file','size':expected['size'],'mode':'0o644','link':None}}
    payload={archive:expected['archiveSHA256']}
    for suffix,limit in [('_content_names',1024*1024),('_hash',65),('_is_first_class_gcs',2)]:
        name=prefix+suffix
        with held_file(root,source_prefix+'/'+name if source_prefix else name,limit) as (stream,before):
            raw=stream.read(before.st_size+1);need(len(raw)==before.st_size,'Tool marker size changed')
        if suffix=='_content_names':
            value=strict_json(raw)
            need(isinstance(value,list) and value==[m['path'] for m in inspection['members']] and
                 len(value)==len(set(value)),'Downloader member list differs from archive')
        else:
            need(raw==((expected['archiveSHA256']+'\n').encode() if suffix=='_hash' else b'1\n'),
                 'Downloader hash or object-class marker invalid')
        records[name]={'path':name,'kind':'file','size':len(raw),'mode':'0o644','link':None}
        payload[name]=hashlib.sha256(raw).hexdigest()
    return records,payload


def merge_installed(members:dict[str,dict[str,Any]],payload:dict[str,str],
                    extra_members:dict[str,dict[str,Any]],extra_payload:dict[str,str]) -> None:
    for name,value in extra_members.items():
        if name in members:
            need(value==members[name] and value['kind']=='directory','Incompatible overlapping tool member')
        else:members[name]=value
    need(not set(payload).intersection(extra_payload),'Overlapping tool file payload')
    payload.update(extra_payload)


def verify_installed(root:Path,members:dict[str,dict[str,Any]],payload:dict[str,str],source_prefix:str='') -> None:
    """Check files, permissions, links and complete installed path coverage."""
    with directory_anchor(root,source_prefix) as root_fd:
        verify_installed_tree(root,source_prefix,root_fd,members,payload)


def verify_installed_tree(root:Path,source_prefix:str,root_fd:int,members:dict[str,dict[str,Any]],payload:dict[str,str]) -> None:
    children={'':set()}
    for name in members:
        parent,_,leaf=name.rpartition('/');children.setdefault(parent,set()).add(leaf)
        if members[name]['kind']=='directory':children.setdefault(name,set())
    stack=[(os.dup(root_fd),'')]
    try:
        while stack:
            directory,prefix=stack.pop()
            try:
                need(set(os.listdir(directory))==children[prefix],'Installed tool path coverage mismatch')
                for leaf in sorted(children[prefix]):
                    name=prefix+'/'+leaf if prefix else leaf;m=members[name]
                    observed=os.stat(leaf,dir_fd=directory,follow_symlinks=False)
                    need(observed.st_uid==os.getuid(),'Installed tool member has wrong owner')
                    if m['kind']=='directory':
                        need(stat.S_ISDIR(observed.st_mode) and stat.S_IMODE(observed.st_mode)==0o755,'Installed tool directory differs')
                        child=os.open(leaf,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=directory)
                        try:need(identity(os.fstat(child))==identity(observed),'Tool directory changed while opening')
                        except BaseException:os.close(child);raise
                        stack.append((child,name))
                    elif m['kind']=='symlink':
                        need(stat.S_ISLNK(observed.st_mode) and os.readlink(leaf,dir_fd=directory)==m['link'] and
                             identity(os.stat(leaf,dir_fd=directory,follow_symlinks=False))==identity(observed),
                             'Installed tool symlink target differs')
                    else:
                        need(stat.S_ISREG(observed.st_mode) and observed.st_size==m['size'] and
                             stat.S_IMODE(observed.st_mode)==int(m['mode'],8),'Installed tool file metadata differs')
                        with held_file(root,source_prefix+'/'+name if source_prefix else name,m['size']) as (stream,before):
                            need(identity(before)==identity(observed) and stream_hash(stream,m['size'])==payload[name],
                                 'Installed tool file bytes differ')
            finally:os.close(directory)
    finally:
        for directory,_ in stack:os.close(directory)


def verify_tool_packages(artifacts:Path,source:Path,additive_output:Path) -> dict[str,Any]:
    secondary=verify_secondary_bundle(artifacts/'m156-secondary-source-preparation-attempt-4',
                                      artifacts/'m156-source-public-preparation-attempt-4')
    raw=read_source_file(artifacts,'m156-DEPS.official',512*1024)
    need(hashlib.sha256(raw).hexdigest()==DEPS_SHA256,'Pinned official DEPS changed')
    origins=deps_packages(raw);tool_root=artifacts/'m156-pinned-toolchain';result=[];installed={};additive={}
    for kind in ['clang','rust']:
        docs={}
        for suffix in ['archive-inspection','payload-sha256']:
            name=kind+'-'+suffix+'.json';raw=read_source_file(tool_root,name,8*1024*1024)
            need(hashlib.sha256(raw).hexdigest()==MANIFEST_PINS[name],'Pinned tool member manifest changed')
            docs[suffix]=strict_json(raw)
        inspected,payload=docs['archive-inspection'],docs['payload-sha256'];expected=PACKAGES[kind]
        members=metadata(inspected,payload,expected)
        need(len(members)==(392 if kind=='clang' else 8705),'Exact official tool member count mismatch')
        # Validate the preserved acquired object separately from the active
        # source's GCS cache; never rewrite either one.
        verify_archive(tool_root,Path(expected['url']).name,inspected,payload,expected)
        markers,marker_payload=downloader_metadata(source,inspected,expected,SOURCE_PREFIX[kind])
        merge_installed(members,payload,markers,marker_payload)
        installed[kind]=(members,payload)
        result.append({'kind':kind,**origins[kind],'regularFiles':expected['files'],
                       'directories':sum(m['kind']=='directory' for m in members.values()),
                       'symlinks':sum(m['kind']=='symlink' for m in members.values()),
                       'archivePayloadAndInstalledSourceToolRootVerified':True})
    expected=TOOL_PACKAGES['llvmobjdump']
    inspected,payload=observe_verified_archive(source,SOURCE_PREFIX['llvmobjdump']+'/'+cached_name(expected),expected)
    need(len(inspected['members'])==8,'Exact llvmobjdump member count required')
    additive={'llvmobjdump-archive-inspection.json':inspected,'llvmobjdump-payload-sha256.json':dict(payload)}
    members=metadata(inspected,payload,expected);markers,marker_payload=downloader_metadata(source,inspected,expected,SOURCE_PREFIX['llvmobjdump'])
    merge_installed(members,payload,markers,marker_payload)
    merge_installed(installed['clang'][0],installed['clang'][1],members,payload)
    need(len(installed['clang'][0])==407 and len(installed['rust'][0])==8709,'Complete installed tool union count mismatch')
    for kind,(members,payload) in installed.items():verify_installed(source,members,payload,SOURCE_PREFIX[kind])
    result.append({'kind':'llvmobjdump',**origins['llvmobjdump'],'regularFiles':6,'directories':1,'symlinks':1,
                   'archivePayloadAndInstalledSourceToolRootVerified':True})
    for name,expected in PROBE_LOGS.items():
        raw=read_source_file(tool_root,name+'-identity.log',1024*1024)
        need(hashlib.sha256(raw).hexdigest()==expected,'Pinned tool version/help log changed')
    receipt={'schemaVersion':1,'status':'selected-official-tool-packages-observed-not-build-qualified',
            'chromiumVersion':VERSION,'officialChromiumBase':{'commit':COMMIT,'tree':TREE},
            'DEPS_SHA256':DEPS_SHA256,'secondaryOriginalFreezeSHA256':secondary['originalFreezeSHA256'],
            'packages':result,'probeLogsVerifiedWithoutPublishingContents':3,
            'symlinkModePolicy':'compare exact relative target; native symlink mode does not represent tar permissions',
            'finalSourceSnapshotAndCompletedBuildBindingStillRequired':True,'otherToolDependencyOriginsStillRequired':True,
            'toolExecution':False,'sourceMutation':False,'nativeBuildInvokedByVerifier':False,
            'binaryBindingVerified':False,'runtimeQualified':False,'releaseReady':False}
    import json
    receipt['additiveMetadataSHA256']={name:hashlib.sha256((json.dumps(doc,sort_keys=True,indent=2,ensure_ascii=True)+'\n').encode()).hexdigest()
                                      for name,doc in additive.items()}
    receipt['installedUnion']={'llvm':{'nodes':407,'payloadFiles':364,'directories':22,'symlinks':13,'downloaderMetadataFiles':8},
                               'rust':{'nodes':8709,'payloadFiles':7259,'directories':1446,'symlinks':0,'downloaderMetadataFiles':4}}
    write_new_store(additive_output,{**additive,'registry.json':receipt})
    return receipt
