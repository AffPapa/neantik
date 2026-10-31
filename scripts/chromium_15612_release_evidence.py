"""Dedicated final9 M156 source/candidate verification.

Authenticate preserved proofs; never transfer a M155 verdict, infer runtime
qualification from source reconstruction, or relabel a private receipt hash
as the canonical manifest. No builds, signing or whole-tree scans here.
"""
from __future__ import annotations
import hashlib,json,re
from pathlib import Path
from typing import Any
from chromium_15612_generated_cache import VERSION,COMMIT,TREE
from chromium_15612_postbuild9 import ARGS_SHA256,require_terminal
from chromium_15612_receipt_projection import checked_file,strict_json,project_value,LEXICAL_RECEIPTS
from chromium_15612_input_lineage import verify_primary_bundle
from chromium_15612_supplemental import verify_secondary_bundle
from chromium_15612_binary_binding9 import observe_regular,require_arm64_header
from runtime_historical_baseline import bound_baseline_path

PREFIX='chromium-15612'
ARGS_RELATIVE='out/NeAntikM156Qualified20261009/args.gn'
EVIDENCE_REGISTRY_SHA256='73ab21ee6b87a5807811a542efada674254290e0efd6827447880f6c55138cd3'
HEX=re.compile(r'[0-9a-f]{64}\Z')
UPSTREAM = {
    'upstreamCommonOverlay': ('https://github.com/ungoogled-software/ungoogled-chromium.git',
        '37085e47cf580c815a30402917d350ce97399ded', 'e0754007a836944e1365c17ce502907594af12f6'),
    'upstreamMacPackaging': ('https://github.com/ungoogled-software/ungoogled-chromium-macos.git',
        'f7ba75f94442abda7ac3ea81790c217f8636d3ba', '019bd2588e47f70b301e09e5475b1b1abd82ad35'),
}
class M15612EvidenceError(ValueError):pass

def need(condition:Any,label:str)->None:
    if not condition:raise M15612EvidenceError(label)

def digest(raw:bytes)->str:return hashlib.sha256(raw).hexdigest()

def sha256_file(path:Path)->str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(65536),b''):h.update(chunk)
    return h.hexdigest()

def safe_relative_regular(root:Path,name:str)->Path:
    need(isinstance(name,str) and name and '\\' not in name and '\x00' not in name and
         not name.startswith('/') and all(p not in {'','.','..'} for p in name.split('/')),
         'Unsafe M156 evidence path')
    target=root/name
    need(not root.is_symlink() and not any(p.is_symlink() for p in (target,*target.parents) if p==root or p.is_relative_to(root))
         and target.is_file(),'M156 evidence missing or symlinked')
    return target

def read_object(path:Path,label:str)->dict:
    path=safe_relative_regular(path.parent,path.name)
    d=strict_json(checked_file(path.parent,path.name))
    need(isinstance(d,dict),label+' must be an object')
    return d

def bound(root:Path,name:str,expected:str)->dict:
    need(isinstance(expected,str) and HEX.fullmatch(expected),'Invalid M156 digest')
    raw=checked_file(root,name)
    need(digest(raw)==expected,'M156 bound file changed: '+name)
    d=strict_json(raw);need(isinstance(d,dict),'M156 object required');return d

def evidence_documents(root:Path)->dict[str,dict]:
    """Pin both derivative bytes and original identities, retaining all fields."""
    registry=bound(root,'registry.json',EVIDENCE_REGISTRY_SHA256)
    need(registry.get('schemaVersion')==1 and registry.get('status')=='prepared-final9-source-evidence' and
         registry.get('version')==VERSION and registry.get('sourceQualified') is False and
         registry.get('runtimeQualified') is False and registry.get('releaseReady') is False,
         'M156 evidence registry identity')
    documents={};names={'registry.json','primary','secondary'}
    records=registry.get('records');need(isinstance(records,list) and len(records)==58,'M156 closed proof count')
    for record in records:
        need(isinstance(record,dict) and set(record)=={'path','originalReceiptSHA256','projectionSHA256'},'M156 record schema')
        name=record['path'];need(name not in names and '/' not in name,'M156 duplicate proof')
        names.add(name);doc=bound(root,name,record['projectionSHA256'])
        need(doc.get('schemaVersion')==1 and doc.get('status')=='source-projection-prepared-unqualified' and
             doc.get('releaseReady') is False and doc.get('payloadType')=='json' and
             doc.get('receipt')+'.projection.json'==name and
             doc.get('originalReceiptSHA256')==record['originalReceiptSHA256'], 'M156 original/projection binding')
        logical=doc['receipt'] if doc['receipt'] in LEXICAL_RECEIPTS else None
        project_value(doc['payload'],{},logical_receipt=logical)
        documents[doc['receipt']]=doc
    need({p.name for p in root.iterdir()}==names,'M156 evidence has missing/extra members')
    verify_primary_bundle(root/'primary');verify_secondary_bundle(root/'secondary',root/'primary')
    return documents

def verify_source_closure(documents:dict[str,dict])->None:
    p=lambda n:documents[n]['payload']
    original=lambda n:documents[n]['originalReceiptSHA256']
    terminal=p('m156-native-build-attempt-9-state.json');require_terminal(terminal)
    freeze=p('m156-prebuild-attempt-9-contract.json');fd=p('m156-postbuild-attempt-9-full-fd-observation.json')
    stage=p('m156-attempt9-source-stage-closure.json');domain=p('m156-independent-domain-cache-replay-attempt-9.json')
    origin=p('m156-pruning-domain-preimage-origin-proof.json');chain=p('m156-subsequent-correction-lineage-attempt-9-v2.json')
    application=p('m156-late-correction-application-proof.json');unsigned=p('m156-attempt9-unsigned-runtime-binding.json')
    need(freeze['attempt']==9 and freeze['chromiumVersion']==VERSION and freeze['officialCommit']==COMMIT and
         freeze['officialTree']==TREE and freeze['argsGN']==ARGS_SHA256 and freeze['jobs']==2 and
         terminal['contractSHA256']==original('m156-prebuild-attempt-9-contract.json'),'M156 frozen build identity')
    need(fd['terminalStateSHA256']==original('m156-native-build-attempt-9-state.json') and
         fd['originalFreezeSHA256']==terminal['contractSHA256'] and fd['terminalLogSHA256']==terminal['logSHA256'] and
         fd['producerExitCode']==0 and fd['exactCoverageVerified'] is True and fd['fdSafeFullObservationVerified'] is True and
         fd['sourceFileCount']==1062644 and fd['explicitCopyGroupsObserved']==83 and
         fd['observedCompactSHA256']==original('m156-postbuild-attempt-9-source-snapshot-compact.json'),
         'M156 final producer/FD/snapshot closure')
    need(stage['fullFDObservationSHA256']==original('m156-postbuild-attempt-9-full-fd-observation.json') and
         stage['observedFullSHA256']==fd['observedFullSHA256'] and stage['requiredFinalImagesVerified']==32634 and
         stage['prunedSourcesAbsent']==13832 and stage['initialPruningAbsencesStillAbsent']==154 and
         stage['domainAbsencesVerified']==855 and stage['noncachedDomainSourcesReplayed']==64 and
         stage['generatedOutputsVerified']==5 and stage['protectedFilesVerified']==2 and
         stage['officialPrimaryImagesVerified']==779 and stage['ownedPrimaryAdditionsAbsent']==26,
         'M156 final source images/origins/absences incomplete')
    for name,h in stage['inputReportsSHA256'].items():
        key='m156-retained-component-origins-attempt8.json' if name=='m156-retained-component-origins-attempt8/report.json' else name
        if key in documents:need(original(key)==h,'M156 stage input differs')
    need(origin['verifiedPreimages']==origin['expectedPreimages']==30905 and origin['issues']==[] and
         origin['preservedPruningPayloadsVerified']==13832 and origin['sourceOrGitMutated'] is False and
         origin['GitPathReaderSHA256']=='930dc09f5cafef17035426b2ca6581d024e6c4abc512b3004e5062b91d303207',
         'M156 authenticated commit/tree/path or retained payload proof incomplete')
    need(domain['terminalStateSHA256']==original('m156-native-build-attempt-9-state.json') and
         domain['changedSourceCount']==17009 and domain['noncachedSourceCount']==64 and
         domain['nativeReceiptSHA256']==original('m156-native-inputs-receipt.json') and
         chain['subsequentPatchCount']==application['closedCorrectionCount']==15 and
         len(chain['requiredFinalSourceImages'])==32634 and len(application['orderedApplications'])==15,
         'M156 ordered/domain/application closure')
    need(unsigned['actualFullFDObservationSHA256']==original('m156-postbuild-attempt-9-full-fd-observation.json') and
         unsigned['terminalStateSHA256']==original('m156-native-build-attempt-9-state.json') and
         unsigned['callerDigestKind']=='private-native-inputs-receipt-not-canonical-source-manifest' and
         unsigned['callerSourceManifestSHA256']==original('m156-native-inputs-receipt.json'),
         'M156 unsigned observation/actual native receipt mismatch')

def _verify_contract(project_root:Path, documents:dict[str,dict])->tuple[dict,dict]:
    runtime=project_root/'runtime';contract=read_object(runtime/(PREFIX+'-source-contract.json'),'M156 contract')
    project_value(contract,{})
    need(contract.get('schemaVersion')==2 and contract.get('status')=='source-qualified' and
         contract.get('targetChromiumVersion')==VERSION and contract.get('targetArchitecture')=='arm64' and
         contract.get('sourceMode')=='official-chromium-owned-macos-port' and contract.get('releaseReady') is False and
         type(contract.get('safeBrowsingMode')) is int and contract['safeBrowsingMode']==0 and
         contract.get('enterpriseCloudContentAnalysis') is True and
         contract.get('officialChromiumBase',{}).get('commit')==COMMIT and
         contract['officialChromiumBase'].get('tree')==TREE and contract.get('buildArgsSHA256')==ARGS_SHA256,
         'M156 source contract identity/policy')
    manifest=bound(runtime,PREFIX+'-source-input-manifest.json',contract.get('sourceInputManifestSHA256'))
    snapshot=bound(runtime,PREFIX+'-source-snapshot.json',contract.get('sourceSnapshotSHA256'))
    toolchain=bound(runtime,PREFIX+'-toolchain-lock.json',contract.get('toolchainLockSHA256'))
    plan=bound(runtime,PREFIX+'-rebase-plan.json',contract.get('rebasePlanSHA256'))
    for doc in (manifest,snapshot,toolchain,plan):project_value(doc,{})
    for key, expected in UPSTREAM.items():
        need(tuple(plan.get(key,{}).get(k) for k in ('repository','commit','tree'))==expected,
             'M156 plan upstream differs from reviewed retained inputs')
    need(plan['upstreamCommonOverlay'].get('patchCount')==109 and
         plan['upstreamCommonOverlay'].get('seriesSHA256')=='4ff99a455ee8e0b6f66c167ebb0b79ec063daa1038ce5bc659a485965d7abae7' and
         plan['upstreamMacPackaging'].get('patchCount')==20 and
         plan['upstreamMacPackaging'].get('seriesSHA256')=='f432ba4b0188b9e4dd4bbe9e1d21760f76048c70df69e70b2d2881ede6378510',
         'M156 upstream patch count/series differs')
    verify_source_closure(documents)
    original=lambda n:documents[n]['originalReceiptSHA256']
    freeze=documents['m156-prebuild-attempt-9-contract.json']['payload']
    need(manifest.get('schemaVersion')==1 and manifest.get('sourceInputsReady') is True and
         manifest.get('releaseReady') is False and manifest.get('chromiumVersion')==VERSION and
         manifest.get('evidenceRegistrySHA256')==EVIDENCE_REGISTRY_SHA256 and
         manifest.get('originalPrebuildContractSHA256')==original('m156-prebuild-attempt-9-contract.json') and
         manifest.get('originalPrebuildSnapshotSHA256')==freeze['sourceSnapshotSHA256'] and
         manifest.get('originalFreezeInputsSHA256')==freeze['inputs'] and
         manifest.get('sourceSnapshotSHA256')==contract['sourceSnapshotSHA256'] and
         manifest.get('originalUnsignedObservationSHA256')==original('m156-attempt9-unsigned-runtime-binding.json') and
         manifest.get('originalNativeInputReceiptSHA256')==original('m156-native-inputs-receipt.json') and
         manifest.get('originalFullFDObservationSHA256')==original('m156-postbuild-attempt-9-full-fd-observation.json') and
         manifest.get('originalSourceStageClosureSHA256')==original('m156-attempt9-source-stage-closure.json') and
         manifest.get('originalTerminalStateSHA256')==original('m156-native-build-attempt-9-state.json') and
         manifest.get('buildArgsSHA256')==ARGS_SHA256,
         'M156 manifest bindings')
    need(snapshot==documents['m156-postbuild-attempt-9-source-snapshot-compact.json']['payload'] and
         snapshot.get('argsGN')=={'relativePath':ARGS_RELATIVE,'sha256':ARGS_SHA256} and
         snapshot.get('targetChromiumVersion')==VERSION,'M156 final snapshot differs')
    need(toolchain.get('schemaVersion')==1 and toolchain.get('chromiumVersion')==VERSION and
         toolchain.get('frozenToolHashes')==documents['m156-prebuild-attempt-9-contract.json']['payload']['nativeToolHashes'] and
         toolchain.get('packageClosureOriginalSHA256')==original('native-tool-package-closure-actual-launch-v2.json') and
         toolchain.get('CIPDOriginOriginalSHA256')==original('m156-cipd-tool-origins-attempt-4.json') and
         toolchain.get('nodeOriginOriginalSHA256')==original('m156-selected-node-origins-attempt-4.json') and
         toolchain.get('pythonProducerSHA256')==freeze['referencePythonSHA256'] and
         toolchain.get('xcodeVersion')==freeze['xcodeVersion'] and toolchain.get('sdkVersion')==freeze['sdkVersion'] and
         toolchain.get('jobs')==freeze['jobs'] and toolchain.get('releaseReady') is False and
         plan.get('chromiumVersion')==VERSION and plan.get('orderedInputCount')==216 and
         plan.get('sourceChangingPatchCount')==212 and plan.get('nativeSupersessionCount')==4 and
         plan.get('subsequentCorrectionCount')==15 and plan.get('releaseReady') is False and
         plan.get('orderedReplayOriginalSHA256')==original('m156-full-source-replay.json') and
         plan.get('lateCorrectionLineageOriginalSHA256')==original('m156-subsequent-correction-lineage-attempt-9-v2.json'),
         'M156 tool/ordered plan binding')
    need(sha256_file(runtime/'apple-device-tuples.json')==contract.get('appleDeviceTuplesSHA256') and
         sha256_file(bound_baseline_path(runtime,contract.get('securityBaselineSHA256')))==contract.get('securityBaselineSHA256'),
         'M156 owned catalog/security baseline binding')
    return contract,snapshot

def verify_contract(project_root:Path)->tuple[dict,dict]:
    # Authenticate the proof once per call, retaining all exact closure checks.
    documents=evidence_documents(project_root/'runtime'/(PREFIX+'-source-evidence'))
    return _verify_contract(project_root, documents)

def _verified_candidate_document(document:dict,*,project_root:Path,source_root:Path|None=None)->tuple[dict,dict]:
    runtime=project_root/'runtime';canonical=read_object(runtime/(PREFIX+'-port-candidate.json'),'M156 candidate')
    need(document==canonical,'M156 candidate differs from reviewed document')
    docs=evidence_documents(runtime/(PREFIX+'-source-evidence'))
    contract,snapshot=_verify_contract(project_root, docs)
    need(document.get('schemaVersion')==1 and document.get('status')=='candidate-bound' and document.get('releaseReady') is False and
         document.get('targetChromiumVersion')==VERSION and document.get('targetArchitecture')=='arm64' and
         document.get('sourceContractSHA256')==sha256_file(runtime/(PREFIX+'-source-contract.json')) and
         document.get('sourceInputManifestSHA256')==contract['sourceInputManifestSHA256'] and
         document.get('sourceSnapshotSHA256')==contract['sourceSnapshotSHA256'],'M156 candidate source mismatch')
    expected=docs['m156-attempt9-unsigned-runtime-binding.json']['payload']['binaryBinding']
    need(document.get('binaryBinding')=={**expected,'status':'bound-to-built-candidate','sourceVersion':VERSION,'architecture':'arm64'},
         'M156 candidate unsigned binary observation mismatch')
    project_value(document,{})
    # Live source validation is deliberately distinct from authenticated
    # preserved proof. Do not silently claim a fresh whole-tree observation.
    if source_root is not None:
        raise M15612EvidenceError('M156 live source requires explicit final9 FD observation; use preserved source proof or reobserve before changed source packaging')

    return contract,snapshot

def verify_candidate_document(document:dict,*,project_root:Path,source_root:Path|None=None)->None:
    _verified_candidate_document(document,project_root=project_root,source_root=source_root)

def verify_unsigned_binary_binding(app:Path,args_gn:Path,document:dict)->None:
    import plistlib
    need(args_gn.parent.name=='NeAntikM156Qualified20261009' and args_gn.name=='args.gn','M156 canonical build args path')
    info=observe_regular(app,'Contents/Info.plist',1024*1024,buffered=True)
    plist=plistlib.loads(info['data']);need(plist.get('CFBundleShortVersionString')==VERSION and
         plist.get('CFBundleExecutable')=='NeAntik Browser','M156 app identity')
    executable=observe_regular(app,'Contents/MacOS/NeAntik Browser',1024**3)
    framework=observe_regular(app,'Contents/Frameworks/NeAntik Browser Framework.framework/Versions/'+VERSION+'/NeAntik Browser Framework',8*1024**3)
    require_arm64_header(executable,2);require_arm64_header(framework,6)
    args=observe_regular(args_gn.parent,args_gn.name,1024*1024)
    binding=document.get('binaryBinding',{})
    for record,key in [(executable,'candidateExecutableSHA256'),(framework,'candidateFrameworkSHA256'),(info,'candidateInfoPlistSHA256'),(args,'argsGNSHA256')]:
        need(binding.get(key)==record['sha256'],'M156 unsigned binary/args changed')

def verify_candidate_lock(lock:dict,*,provenance:dict,project_root:Path)->None:
    runtime=project_root/'runtime'
    need(lock==read_object(runtime/('fingerprint-'+PREFIX+'.lock.json'),'M156 lock'),'M156 lock differs')
    contract,_=_verified_candidate_document(provenance,project_root=project_root)
    plan=read_object(runtime/(PREFIX+'-rebase-plan.json'),'M156 plan')
    need(lock.get('schemaVersion')==4 and lock.get('status')=='source-qualified' and lock.get('releaseReady') is False and
         lock.get('targetArchitecture')=='arm64' and lock.get('sourceContract')=='runtime/'+PREFIX+'-source-contract.json' and
         lock.get('sourceContractSHA256')==sha256_file(runtime/(PREFIX+'-source-contract.json')) and
         lock.get('sourceProvenance')=='runtime/'+PREFIX+'-port-candidate.json' and
         lock.get('sourceProvenanceSHA256')==sha256_file(runtime/(PREFIX+'-port-candidate.json')) and
         lock.get('fingerprintChromium',{}).get('chromiumVersion')==VERSION and
         lock['fingerprintChromium'].get('commit')==COMMIT and lock['fingerprintChromium'].get('tree')==TREE,
         'M156 lock source identity')
    for key,plan_key in [('commonChromium','upstreamCommonOverlay'),('macPackaging','upstreamMacPackaging')]:
        need(all(lock.get(key,{}).get(k)==plan[plan_key].get(k) for k in ['repository','commit','tree']),'M156 upstream identity')
    need(lock.get('macPackaging',{}).get('packagedChromiumVersion')==VERSION and
         lock.get('binaryBinding',{}).get('requiredEvidence')=='runtime/'+PREFIX+'-port-candidate.json' and
         lock.get('ownedManifests',{}).get('securityBaselineSHA256')==contract['securityBaselineSHA256'],
         'M156 lock manifest/binary policy')
    # Pending is honest. Promotion needs its own exact signed/GUI wrapper;
    # successful research fixtures never turn into production qualification.
    need(lock.get('verification',{}).get('coherentAppleDeviceTuples')=='pending','M156 tuple qualification wrapper not implemented')
    project_value(lock,{})

def verify_packaged_tuple_qualification(project_root:Path,packaged_evidence:Path,lock:dict)->None:
    need(lock.get('verification',{}).get('coherentAppleDeviceTuples')=='pending',
         'M156 tuple promotion needs independently authenticated final GUI wrapper')
    # Even pending source-only packaging must retain the reviewed evidence.
    reviewed=project_root/'runtime'/(PREFIX+'-source-evidence')
    packaged=packaged_evidence/(PREFIX+'-source-evidence')
    evidence_documents(packaged)
    need(sha256_file(packaged/'registry.json')==sha256_file(reviewed/'registry.json'),'Packaged M156 evidence differs')
