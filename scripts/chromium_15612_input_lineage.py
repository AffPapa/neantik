#!/usr/bin/env python3
"""Validate M156 input lineage, not final source/binary/runtime qualification.

Four reviewed native supersessions are ordered inputs but are not applied
patches. Their secondary evidence needs a separate closure, preserved apart
from the immutable25-document primary projection registry.
"""
from __future__ import annotations
import hashlib
from pathlib import Path
from typing import Any
from chromium_15612_generated_cache import COMMIT,TREE,VERSION,HASH,need,relative_path
from chromium_15612_receipt_projection import (
    NAME,checked_file,strict_json,verify_prepared,
)

PRIMARY_REGISTRY_SHA256='7471cb363ffa17469c868afcfe271ae4417b6cd79edefd5f3e87af01fa5602e5'
FREEZE_SHA256='3593e29cb4eaaed98b0fa7b97a5e0c7710328d8b2e9da6482c5491307eb62c48'
DEPS_SHA256='b4de748ba5abac43952bdc0945795d9c3a07238d18b37ae0f82231669f68fc94'
SUPERSEDED=frozenset({
    'common:core/ungoogled-chromium/build-with-wasm-rollup.patch',
    'macos:ungoogled-chromium/macos/fix-build-without-crubit.patch',
    'owned:m154-include-safe-browsing-prefs-in-enterprise-upload',
    'owned:m154-prune-disabled-signin-status-chip-helper',
})
BASE='m156-shadow-replay-state.json'
SEMANTIC='m156-semantic-shadow-state.json'
CANONICAL='m156-canonical-shadow-state.json'
FULL='m156-full-source-replay.json'
ACQUISITION='m156-acquisition-exact-gates.json'


def is_hash(value: Any) -> bool:
    return isinstance(value,str) and HASH.fullmatch(value) is not None


def verify_lineage(documents: dict[str,dict[str,Any]]) -> dict[str,Any]:
    """Semantic validation of already authenticated projected documents."""
    required=(BASE,SEMANTIC,CANONICAL,FULL,ACQUISITION)
    need(isinstance(documents,dict) and all(name in documents and isinstance(documents[name],dict) and
         isinstance(documents[name].get('payload'),dict) and is_hash(documents[name].get('originalReceiptSHA256'))
         for name in required),'M156 lineage receipt missing or malformed')
    payload=lambda name:documents[name]['payload']
    original=lambda name:documents[name]['originalReceiptSHA256']
    base,semantic,canonical,full,acquisition=(payload(n) for n in (BASE,SEMANTIC,CANONICAL,FULL,ACQUISITION))
    need(all(isinstance(d,dict) and d.get('releaseReady') is False and d.get('nativeBuildStarted') is False
             for d in (base,semantic,canonical,full,acquisition)), 'Mixed qualified/unqualified input stages')
    need(all(type(d.get('schemaVersion')) is int and d['schemaVersion']==1 for d in (base,full,acquisition)),
         'M156 input schema invalid')
    need(full.get('officialCommit')==COMMIT and full.get('officialTree')==TREE and
         full.get('status')=='full-source-replay-complete-unqualified', 'M156 full replay identity mismatch')
    need(all(d.get('commit')==COMMIT for d in (base,semantic,canonical)) and base.get('targetVersion')==VERSION and
         base.get('status')==semantic.get('status')=='partial-shadow-replay-complete-still-unqualified' and
         canonical.get('status')=='canonical-shadow-replay-complete-still-unqualified', 'M156 shadow identity mismatch')
    expected_lineage={name:original(name) for name in (BASE,SEMANTIC,CANONICAL)}
    need(all(is_hash(sha) for sha in expected_lineage.values()) and full.get('inputReceipts')==expected_lineage and
         semantic.get('baseReplaySHA256')==original(BASE) and canonical.get('baseReplaySHA256')==original(BASE) and
         canonical.get('semanticReplaySHA256')==original(SEMANTIC) and
         full.get('acquisitionReceiptSHA256')==original(ACQUISITION), 'M156 ordered lineage hash mismatch')
    need(acquisition.get('officialCommit')==COMMIT and acquisition.get('officialTree')==TREE and
         acquisition.get('DEPS_SHA256')==DEPS_SHA256 and acquisition.get('hooksExecuted') is False,
         'M156 acquisition identity mismatch')
    counts={'git':151,'gcs':50,'cipd':39,'processed':240}
    need(all(type(acquisition.get(k)) is int and acquisition[k]==v for k,v in counts.items()),
         'M156 acquisition counts invalid')
    acquired=acquisition.get('records')
    need(isinstance(acquired,dict) and len(acquired)==240 and
         all(isinstance(record,dict) and record.get('kind') in {'git','gcs','cipd'} for record in acquired.values()) and
         all(sum(record['kind']==kind for record in acquired.values())==count for kind,count in counts.items() if kind!='processed'),
         'M156 acquisition coverage invalid')
    stages=[('base',base,202),('semantic',semantic,7),('canonical',canonical,7)]
    ordered=[]
    for series,stage,count in stages:
        records=stage.get('records')
        need(isinstance(records,list) and len(records)==count,'M156 stage input count invalid')
        ordered.extend((series,record) for record in records)
    records=full.get('records')
    need(isinstance(records,list) and len(records)==216,'M156 full input count invalid')
    labels=[];current={};superseded={};compared_outputs=0
    record_keys={'series','label','patchPath','patchSHA256','preimages','postimages','applyOutputSHA256'}
    for record,(series,origin) in zip(records,ordered,strict=True):
        need(isinstance(record,dict) and set(record)==record_keys and isinstance(origin,dict),
             'M156 replay record schema invalid')
        label=record['label']
        need(isinstance(label,str) and 0<len(label)<=512 and label not in labels and record['series']==series and
             label==origin.get('label') and is_hash(record['applyOutputSHA256']), 'M156 replay order/input invalid')
        if label in SUPERSEDED:
            need(record['patchPath'] is None and record['patchSHA256'] is None and
                 record['applyOutputSHA256']==hashlib.sha256(b'Reviewed native supersession').hexdigest(),
                 'Superseded input falsely marked as applied patch')
        else:
            need(isinstance(record['patchPath'],str) and 0<len(record['patchPath'])<=4096 and
                 is_hash(record['patchSHA256']),'Applied patch input missing')
            relative_path(record['patchPath'])
            if series=='canonical':
                need(record['patchPath']==origin.get('path'),'Canonical patch path differs from reviewed input')
        labels.append(label)
        origin_hash=origin.get('sha256') if series=='canonical' else origin.get('patchSHA256')
        need(record['patchSHA256']==origin_hash and record['preimages']==origin.get('preimages') and
             record['postimages']==origin.get('postimages'), 'M156 replay differs from reviewed shadow')
        pre,post=record['preimages'],record['postimages']
        need(isinstance(pre,dict) and isinstance(post,dict) and 0<len(pre)<=4096 and set(pre)==set(post),
             'M156 replay image coverage invalid')
        for name,value in pre.items():
            relative_path(name)
            need((value is None or is_hash(value)) and (post[name] is None or is_hash(post[name])),
                 'Invalid replay source digest')
            need(name not in current or current[name]==value,'Broken ordered source preimage chain')
        current.update(post)
        if label in SUPERSEDED:
            evidence=origin.get('evidence')
            need(series=='base' and pre==post and origin.get('action')=='native-superseded' and
                 origin.get('ported') is False and is_hash(origin.get('originalPatchSHA256')) and
                 'applyOutputSHA256' not in origin and isinstance(evidence,dict) and 1<=len(evidence)<=16 and
                 all(isinstance(n,str) and NAME.fullmatch(n) and n.endswith('.json') and is_hash(h) for n,h in evidence.items()),
                 'M156 supersession decision missing')
            superseded[label]=dict(evidence)
        else:
            need(pre!=post and origin.get('applyOutputSHA256')==record['applyOutputSHA256'],
                 'Applied patch has no source delta or output binding')
            compared_outputs+=1
    need(set(superseded)==SUPERSEDED and compared_outputs==212 and
         sum(n.startswith('common:') for n in labels[:202])==109 and
         sum(n.startswith('macos:') for n in labels[:202])==20 and
         sum(n.startswith('owned:') for n in labels[:202])==73, 'M156 series/supersession coverage invalid')
    return {'schemaVersion':1,'status':'reviewed-primary-input-lineage-verified-only',
            'chromiumVersion':VERSION,'officialChromiumBase':{'commit':COMMIT,'tree':TREE},
            'orderedInputCount':216,'sourceChangingPatchCount':212,'nativeSupersessionCount':4,
            'shadowApplyOutputBindingsCompared':compared_outputs,'stageReplayPostimages':current,
            'supersessionEvidenceReferences':superseded,'secondaryEvidenceClosureStillRequired':True,
            'subsequentCorrectionChainStillRequired':True,'sourceSnapshotVerified':False,
            'binaryBindingVerified':False,'runtimeQualified':False,'releaseReady':False}


def primary_documents(root: Path) -> dict[str,dict[str,Any]]:
    # Existing checker already authenticates all25 primary projections and
    # their closed set. Do not clone or weaken that implemented verifier.
    registry=verify_prepared(root,contract_name='m156-prebuild-attempt-4-contract.json',
                             contract_sha256=FREEZE_SHA256,registry_sha256=PRIMARY_REGISTRY_SHA256)
    need(len(registry['receipts'])==25,'Exact M156 primary receipt set required')
    documents={}
    for record in registry['receipts']:
        raw=checked_file(root,record['path'])
        need(hashlib.sha256(raw).hexdigest()==record['projectionSHA256'],'Projection changed after validation')
        document=strict_json(raw)
        documents[document['receipt']]=document
    return documents


def verify_primary_bundle(root: Path) -> dict[str,Any]:
    result=verify_lineage(primary_documents(root))
    result.update(primaryProjectionRegistrySHA256=PRIMARY_REGISTRY_SHA256,originalFreezeSHA256=FREEZE_SHA256)
    return result
