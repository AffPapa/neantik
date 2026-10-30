#!/usr/bin/env python3
"""Bind reviewed secondary source receipts without altering the primary freeze.

This closes decision-reference edges only. It does not attest live toolchain
payloads, current source files, a finished build, or a release.
"""
from __future__ import annotations
import hashlib
import json
import os
import stat
from pathlib import Path
from typing import Any
from chromium_15612_generated_cache import COMMIT,VERSION,need,relative_path
from chromium_15612_input_lineage import (
    BASE,ACQUISITION,PRIMARY_REGISTRY_SHA256,FREEZE_SHA256,
    primary_documents,verify_lineage,is_hash,
)
from chromium_15612_receipt_projection import checked_file,strict_json,projection,project_value,LOGICAL_RECEIPTS,LEXICAL_RECEIPTS

PINS={
 'm156-DEPS-receipt.json':'afd64acb2504007f5b37ae8e9a490e72cfd22009d27fb776a81b1dfc7bfb6c82',
 'm156-devtools-absent-targets.json':'125090427f9c6fe33f1cbeb1c5e58384852b7cc294b6e297b61aaf2e8aa9e161',
 'm156-devtools-bundle-source-receipt.json':'6e82790246c9b54a2ffc6c05a383a1f0a2fd9698772d62982579444429a0c289',
 'm156-devtools-source-receipts.json':'5f07a42944f44f8bd4ccafbc0c654e11b8edd8278d9cd09e5fb9ae725bfdd4dc',
 'm156-crubit-native-supersession.json':'99fd8630b4b7ae5cf2b7bb6091d99e0398bb6a1a5dd72056475e1941225d0d83',
 'm156-pinned-toolchain-probes.json':'4e5409179227750c7dffc2f3e0b67f1b75d21540383113bd182820d5b39ffea8',
 'm156-pinned-toolchain-receipt.json':'d1919dd1b5d6915cedd248be2080a160e6aadd06c3de45b6a647c3187c362d2a',
 'm156-enterprise-upload-native-include-supersession.json':'1c17ae041f3a2865748fb04735c0c3d50921d5b9ffcb5a0b1f7cf36b72672d14',
 'm156-signin-chip-local-removal-supersession.json':'0296a8fd64382dc0f400bf087c6ea95b7772db984505eb7d031789c6eca0a631',
 'm156-nasm-source-receipts.json':'ffe8387d0df8a8eab934d29ce4c22e69038ed4c1061b961ed7447d22f0f5e678',
}
DEVTOOLS='2d671c506c4e5f8958b027e26047deb0acfbd7f9'
NASM='525a09a813be0f75b646ee93fc2a31c27b87d722'
SECONDARY_REGISTRY_SHA256='17944b965ae002889f6e30e03ba242201c37bc0a168ddcbd4230440ca66cdfe0'
PACKAGES={
 'clang':{'url':'https://commondatastorage.googleapis.com/chromium-browser-clang/Mac_arm64/clang-llvmorg-24-init-7747-g62397f8b-53.tar.xz',
          'archiveSHA256':'7ce015cde974fc32bb80e1f48aa7dddbdcbe44fd6f8614de5e63cae4733960d5','size':44452152,'files':358},
 'rust':{'url':'https://commondatastorage.googleapis.com/chromium-browser-clang/Mac_arm64/rust-toolchain-1edd55dcfcd573872c727fa3e086369a71661ee0-2-llvmorg-24-init-7747-g62397f8b.tar.xz',
         'archiveSHA256':'5db21ffd4909ce82c0832df9d1eb06b01b15a54176b7341e39f7181f4b483dbc','size':248304876,'files':7259},
}


def verify_decision_edges(primary:dict[str,dict[str,Any]], documents:dict[str,dict[str,Any]]) -> list[dict[str,Any]]:
    """Check authenticated source decisions against their ordered replay stage."""
    lineage=verify_lineage(primary)
    need(isinstance(documents,dict) and set(documents)==set(PINS), 'Supplemental closed set mismatch')
    for name,document in documents.items():
        need(isinstance(document,dict) and document.get('originalReceiptSHA256')==PINS[name] and
             document.get('receipt')==name and isinstance(document.get('payload'),dict) and
             document.get('releaseReady') is False, 'Supplemental document identity mismatch')
    value=lambda name:documents[name]['payload']
    base=primary[BASE]['payload'];acq=primary[ACQUISITION]['payload'];edges=[]
    for index,record in enumerate(base['records']):
        if record['label'] not in lineage['supersessionEvidenceReferences']:continue
        for name,digest in sorted(record['evidence'].items()):
            need(name in PINS and digest==PINS[name], 'Unbound supersession reference')
            edges.append({'parentOriginalReceipt':BASE,'parentOriginalSHA256':primary[BASE]['originalReceiptSHA256'],
                          'jsonPointer':f'/records/{index}/evidence/{name}', 'role':'native-supersession-source-decision',
                          'targetName':name,'targetOriginalSHA256':digest})
    need(len(edges)==10 and {e['targetName'] for e in edges}==set(PINS)-{'m156-nasm-source-receipts.json'},
         'Incomplete supersession reference coverage')
    for index,name in [(124,'m156-crubit-native-supersession.json'),
                       (163,'m156-enterprise-upload-native-include-supersession.json'),
                       (185,'m156-signin-chip-local-removal-supersession.json')]:
        d=value(name);stage=base['records'][index]
        need(d.get('commit')==COMMIT and d.get('preimages')==stage['preimages']==stage['postimages'],
             'Decision observation differs from its replay stage')
    crubit=value('m156-crubit-native-supersession.json')
    need(crubit.get('nativeBuildVerified') is False and crubit.get('releaseReady') is False and
         crubit.get('toolchainProbes')=='m156-pinned-toolchain-probes.json' and
         crubit.get('checks')=={'components/cbor/BUILD.gn':'gn-source://build/rust/crubit',
          'components/web_package/BUILD.gn':'gn-source://components/web_package/rust:web_package_rust_bindings',
          'third_party/blink/renderer/platform/fonts/BUILD.gn':'cpp_api_from_rust'},
         'Native Crubit decision contract invalid')
    for name in ['m156-enterprise-upload-native-include-supersession.json','m156-signin-chip-local-removal-supersession.json']:
        d=value(name);need(d.get('path') in d['preimages'] and is_hash(d.get('pristineSHA256')),
                          'Missing separate pristine-source observation')
    # These are observations of pre-patch source and a moved target. Do not
    # compare them blindly with final postimages after later common patches.
    sources=value('m156-devtools-source-receipts.json')
    need(len(sources)==13,'DevTools source observation count mismatch')
    for name,record in sources.items():
        relative_path(name)
        need(name.startswith('third_party/devtools-frontend/src/') and isinstance(record,dict) and
             record.get('pin')==DEVTOOLS and is_hash(record.get('sha256')) and
             type(record.get('size')) is int and record['size']>0, 'DevTools source origin mismatch')
    for name,digest in base['records'][34]['preimages'].items():
        if digest is not None:
            need(name in sources and sources[name]['sha256']==digest,
                 'DevTools present source differs from supersession stage')
    absent=value('m156-devtools-absent-targets.json')
    missing='third_party/devtools-frontend/src/scripts/build/build_inspector_overlay.py'
    need(absent.get('pin')==DEVTOOLS and absent.get('targets')==[missing] and
         missing in base['records'][34]['preimages'] and base['records'][34]['preimages'][missing] is None,
         'Moved DevTools target missing stage binding')
    bundle=value('m156-devtools-bundle-source-receipt.json')
    need(bundle.get('pin')==DEVTOOLS and bundle.get('path')=='scripts/build/ninja/bundle.gni' and
         bundle.get('sha256')=='807673e688dc0d325510a86e5fc0f4fc38c071acab00b07c4e9d8f8a4cc19ffc',
         'DevTools bundle source mismatch')
    for key,pin in [('src/third_party/devtools-frontend/src/',DEVTOOLS),('src/third_party/nasm/',NASM)]:
        need(acq['records'].get(key,{}).get('kind')=='git' and
             acq['records'][key].get('revision')==pin,'Supplemental dependency differs from acquisition')
    nasm=value('m156-nasm-source-receipts.json');path='third_party/nasm/config/config-mac.h'
    need(set(nasm)=={path} and nasm[path].get('pin')==NASM and
         nasm[path].get('sha256')==base['records'][122]['preimages'].get(path) and
         base.get('depHydrationReceipt')=='m156-nasm-source-receipts.json', 'NASM hydration preimage mismatch')
    edges.append({'parentOriginalReceipt':BASE,'parentOriginalSHA256':primary[BASE]['originalReceiptSHA256'],
                  'jsonPointer':'/depHydrationReceipt','role':'independently-pinned-pristine-hydration',
                  'targetName':'m156-nasm-source-receipts.json','targetOriginalSHA256':PINS['m156-nasm-source-receipts.json']})
    probes=value('m156-pinned-toolchain-probes.json')
    need(probes.get('nativeBuildStarted') is False and probes.get('releaseReady') is False and
         set(probes.get('probes',{}))=={'clang','rustc','crubit'},'Tool probe contract invalid')
    for probe in probes['probes'].values():
        need(isinstance(probe,dict) and type(probe.get('exitCode')) is int and probe['exitCode']==0 and
             is_hash(probe.get('executableSHA256')) and is_hash(probe.get('logSHA256')),
             'Invalid tool identity probe')
    freeze=primary['m156-prebuild-attempt-4-contract.json']['payload']
    for name,path in [('clang','third_party/llvm-build/Release+Asserts/bin/clang'),
                      ('rustc','third_party/rust-toolchain/bin/rustc'),
                      ('crubit','third_party/rust-toolchain/bin/cc_bindings_from_rs')]:
        need(probes['probes'][name]['executableSHA256']==freeze['nativeToolHashes'].get(path),
             'Probe executable differs from frozen tool')
    tool=value('m156-pinned-toolchain-receipt.json')
    need(tool.get('nativeInputsModified') is False and tool.get('nativeBuildStarted') is False and
         tool.get('releaseReady') is False and isinstance(tool.get('packages'),list) and
         len(tool['packages'])==2 and all(isinstance(p,dict) for p in tool['packages']) and
         {p.get('kind') for p in tool['packages']}=={'clang','rust'},
         'Unqualified official package contract invalid')
    for package in tool['packages']:
        expected=PACKAGES[package['kind']]
        need(set(package)=={'kind','url','archiveSHA256','size','files','directory','status'} and
             all(package[key]==expected[key] and type(package[key]) is type(expected[key]) for key in expected) and
             isinstance(package['directory'],str) and package['directory'].startswith('root:') and
             package['status']=='verified-official-package-extracted','Official package origin tuple mismatch')
    return edges


def prepare_secondary(artifact_root:Path,primary_root:Path,roots:dict[str,Path],output:Path) -> dict[str,Any]:
    primary=primary_documents(primary_root)
    documents={};raw_hashes={}
    for name,digest in sorted(PINS.items()):
        raw=checked_file(artifact_root,name)
        need(hashlib.sha256(raw).hexdigest()==digest,'Pinned secondary receipt changed')
        documents[name]=projection(raw,name,roots)
        data=(json.dumps(documents[name],sort_keys=True,indent=2,ensure_ascii=True)+'\n').encode()
        raw_hashes[name]=hashlib.sha256(data).hexdigest()
    deps=checked_file(artifact_root,'m156-DEPS.official')
    receipt=documents['m156-DEPS-receipt.json']['payload']
    need(receipt.get('commit')==COMMIT and receipt.get('sha256')==primary[ACQUISITION]['payload']['DEPS_SHA256'] and
         hashlib.sha256(deps).hexdigest()==receipt['sha256'] and
         hashlib.sha1(b'blob '+str(len(deps)).encode()+b'\0'+deps).hexdigest()==receipt.get('gitBlob'),
         'Supplemental DEPS source bytes mismatch')
    lines=deps.decode('utf-8').splitlines()
    for snippets in receipt['references'].values():
        for number,text in snippets:
            need(type(number) is int and 1<=number<=len(lines) and lines[number-1]==text,
                 'DEPS source reference line mismatch')
    edges=verify_decision_edges(primary,documents)
    for edge in edges:edge['targetProjectionSHA256']=raw_hashes[edge['targetName']]
    registry={'schemaVersion':1,'status':'secondary-source-decisions-bound-unqualified',
              'chromiumVersion':VERSION,'primaryRegistrySHA256':PRIMARY_REGISTRY_SHA256,
              'originalFreezeSHA256':FREEZE_SHA256,'edges':edges,
              'receipts':[{'name':name,'originalSHA256':PINS[name],'projectionSHA256':raw_hashes[name]} for name in sorted(PINS)],
              'toolPackagePayloadClosureStillRequired':True,'subsequentCorrectionChainStillRequired':True,
              'sourceSnapshotVerified':False,'binaryBindingVerified':False,'runtimeQualified':False,'releaseReady':False}
    # Validate everything before first write. Immutable owned outputs cannot
    # replace the25-document primary registry or any previous preparation.
    write_new_store(output,{**{name+'.projection.json':doc for name,doc in documents.items()},'registry.json':registry})
    return registry


def write_new_store(output:Path,documents:dict[str,dict[str,Any]]) -> None:
    """Anchor exclusive writes to a private directory, rejecting replacement."""
    from chromium_15612_receipt_projection import NAME
    need(output.name not in {'','.','..'} and all(NAME.fullmatch(name) for name in documents),
         'Unsafe supplemental output name')
    parent_fd=os.open(output.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    directory_fd=None
    try:
        os.mkdir(output.name,mode=0o700,dir_fd=parent_fd)
        directory_fd=os.open(output.name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent_fd)
        opened=os.fstat(directory_fd)
        need(stat.S_ISDIR(opened.st_mode) and opened.st_uid==os.getuid() and
             stat.S_IMODE(opened.st_mode)==0o700,'Supplemental output directory is not private')
        def still_owned():
            current=os.stat(output.name,dir_fd=parent_fd,follow_symlinks=False)
            need(stat.S_ISDIR(current.st_mode) and (current.st_dev,current.st_ino)==(opened.st_dev,opened.st_ino),
                 'Supplemental output directory replaced')
        for name,document in documents.items():
            still_owned()
            data=(json.dumps(document,sort_keys=True,indent=2,ensure_ascii=True)+'\n').encode()
            fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory_fd)
            with os.fdopen(fd,'wb') as stream:
                stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.fsync(directory_fd)
        os.fsync(parent_fd)
        still_owned()
    finally:
        if directory_fd is not None:os.close(directory_fd)
        os.close(parent_fd)


def verify_secondary_bundle(output:Path,primary_root:Path) -> dict[str,Any]:
    """Authenticate the exact preserved secondary store before semantic use.

    This independent registry pin comes from the separately inspected owned
    preparation, not from the store being verified or a moving latest file.
    """
    need(not output.is_symlink() and output.is_dir(),'Secondary store must be a regular directory')
    raw=checked_file(output,'registry.json')
    need(hashlib.sha256(raw).hexdigest()==SECONDARY_REGISTRY_SHA256,'Pinned secondary registry changed')
    registry=strict_json(raw)
    need(isinstance(registry,dict) and registry.get('primaryRegistrySHA256')==PRIMARY_REGISTRY_SHA256 and
         registry.get('originalFreezeSHA256')==FREEZE_SHA256 and registry.get('chromiumVersion')==VERSION and
         registry.get('status')=='secondary-source-decisions-bound-unqualified' and
         all(registry.get(key) is False for key in ['sourceSnapshotVerified','binaryBindingVerified','runtimeQualified','releaseReady']) and
         registry.get('toolPackagePayloadClosureStillRequired') is True and
         registry.get('subsequentCorrectionChainStillRequired') is True,'Secondary registry boundary invalid')
    records=registry.get('receipts')
    need(isinstance(records,list) and len(records)==len(PINS),'Secondary registry coverage invalid')
    document_keys={'schemaVersion','status','receipt','originalReceiptSHA256','normalizationPolicy',
                   'reviewedLogicalReceiptSHA256','rootAliases','payloadType','payload','releaseReady'}
    docs={};projection_hashes={}
    for record in records:
        need(isinstance(record,dict) and set(record)=={'name','originalSHA256','projectionSHA256'} and
             isinstance(record['name'],str) and record['name'] in PINS and record['name'] not in docs and
             record['originalSHA256']==PINS[record['name']] and is_hash(record['projectionSHA256']),
             'Secondary projection binding invalid')
        name=record['name'];raw=checked_file(output,name+'.projection.json')
        need(hashlib.sha256(raw).hexdigest()==record['projectionSHA256'],'Secondary projection changed')
        doc=strict_json(raw)
        need(isinstance(doc,dict) and set(doc)==document_keys and type(doc['schemaVersion']) is int and
             doc['schemaVersion']==1 and doc['status']=='source-projection-prepared-unqualified' and
             doc['receipt']==name and doc['originalReceiptSHA256']==PINS[name] and
             doc['reviewedLogicalReceiptSHA256']==LOGICAL_RECEIPTS.get(name) and
             doc['normalizationPolicy']=='explicit-root-aliases-v1; every field and record retained' and
             doc['payloadType']=='json' and isinstance(doc['payload'],dict) and doc['releaseReady'] is False and
             doc['rootAliases']==['evidence','research'],'Secondary projected document invalid')
        project_value(doc['payload'],{},logical_receipt=name if name in LEXICAL_RECEIPTS else None)
        docs[name]=doc;projection_hashes[name]=record['projectionSHA256']
    need(set(docs)==set(PINS) and {p.name for p in output.iterdir()}=={'registry.json'}|{n+'.projection.json' for n in PINS},
         'Secondary store missing or extra file')
    primary=primary_documents(primary_root)
    edges=verify_decision_edges(primary,docs)
    for edge in edges:edge['targetProjectionSHA256']=projection_hashes[edge['targetName']]
    need(registry.get('edges')==edges,'Secondary source-decision edges changed')
    return registry
