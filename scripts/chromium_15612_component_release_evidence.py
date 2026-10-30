"""Pinned additive completion successor; source/sign lineage is not release QA.

The immutable security/font predecessors are verified first. Only the three
manifest-selected files may change; test evidence never grants route authority.
"""
from __future__ import annotations

import copy
from pathlib import Path

import chromium_15612_release_evidence as base
import chromium_15612_security_release_evidence as parent
import chromium_additive_source_delta as delta

VARIANT = 'component-completion-v1'
PREFIX = 'chromium-15612-' + VARIANT
ARGS_RELATIVE = 'out/NeAntikComponentQA_20261016/args.gn'
ARGS_SHA256 = parent.ARGS_SHA256
PROOF_SHA256 = 'ec437a25085a5ae1087acc3c5550608891c615903a35e7e0c0a0f048d0e72d39'
MANIFESTS = {
    'runtime/component-updates-v1/manifest.json': 'bf9b3b144c0c5ec3861e4d4381be2888a05ae0938067f573c9c6bc7812055da6',
    'runtime/component-updates-v1/native-tests/manifest.json': '1d2487a7238cb1667907ad2e9bd0f6b6eef3c2a2db7ce2473ab3640573a16ca9',
}
EXE, FRAMEWORK = parent.EXE, parent.FRAMEWORK


def _object(project: Path, suffix: str) -> dict:
    return base.read_object(project / 'runtime' / (PREFIX + '-' + suffix + '.json'), suffix)


def predecessor(project: Path, proof: dict) -> dict:
    return {
        'sourceContractSHA256': base.sha256_file(project / 'runtime' / (parent.PREFIX + '-source-contract.json')),
        'sourceSnapshotSHA256': base.sha256_file(project / 'runtime' / (parent.PREFIX + '-source-snapshot.json')),
        'sourceDeltaProofSHA256': parent.PROOF_SHA256,
        'fullFDObservationSHA256': proof['postbuildObservation']['receiptSHA256'],
        'fullInventorySHA256': proof['postbuildObservation']['fullInventorySHA256'],
    }


def verify_projection(project: Path, proof: dict, ancestor_contract: dict,
                      ancestor_snapshot: dict, ancestor_proof: dict) -> None:
    base.need(isinstance(proof, dict) and set(proof) == {
        'schemaVersion', 'kind', 'sourceVariant', 'targetChromiumVersion', 'releaseReady',
        'base', 'overlayManifestPins', 'changes', 'sourceSnapshotSHA256',
        'postbuildObservation', 'build', 'signing', 'developmentObservation', 'limitations'},
        'Component source proof fields differ')
    base.need(type(proof['schemaVersion']) is int and proof['schemaVersion'] == 1
              and proof['kind'] == 'component-completion-executed-build-and-postbuild-source-proof'
              and proof['sourceVariant'] == VARIANT and proof['targetChromiumVersion'] == base.VERSION
              and proof['releaseReady'] is False and proof['base'] == predecessor(project, ancestor_proof)
              and proof['overlayManifestPins'] == MANIFESTS, 'Component predecessor/identity differs')
    specs = delta.load_inputs(project, MANIFESTS)
    build = proof['build']
    base.need(isinstance(build, dict) and set(build) == {
        'receiptSHA256', 'logSHA256', 'targets', 'jobs', 'exitCode', 'argsSHA256',
        'sourcePostimages', 'sourcePostimagesUnchanged', 'sourceInputsUnchanged',
        'oldInputsPreserved', 'toolsPreserved', 'binaryBinding', 'toolHashes'}, 'Component build fields differ')
    base.need(build['targets'] == ['neantik_component_completion_tests', 'chrome']
              and type(build['jobs']) is int and build['jobs'] == 2
              and type(build['exitCode']) is int and build['exitCode'] == 0
              and build['argsSHA256'] == ARGS_SHA256
              and all(build[k] is True for k in ('sourcePostimagesUnchanged',
                  'sourceInputsUnchanged', 'oldInputsPreserved', 'toolsPreserved'))
              and build['toolHashes'] == ancestor_proof['build']['toolHashes'], 'Component build inputs differ')
    old_post = ancestor_proof['build']['sourcePostimages']
    new_post = build['sourcePostimages']
    base.need(isinstance(new_post, dict) and set(new_post) == set(old_post) | set(specs)
              and not set(old_post).intersection(specs)
              and {n: new_post[n] for n in old_post} == old_post,
              'Component overlay changed or omitted predecessor source')
    delta.verify_projection(proof['changes'], specs, {n: new_post[n] for n in specs})
    obs = proof['postbuildObservation']
    base.need(isinstance(obs, dict) and set(obs) == {
        'receiptSHA256', 'fullInventorySHA256', 'ancestorFullSHA256',
        'historicalBuildObservationRelabeled', 'atomicFilesystemSnapshot',
        'exclusiveSourceCustodyRequired', 'sourceExecution', 'observation',
        'deletedPathCount', 'deletedPathsSHA256'}, 'Component FD observation fields differ')
    measured = obs['observation']
    base.need(obs['ancestorFullSHA256'] == proof['base']['fullInventorySHA256']
              and obs['historicalBuildObservationRelabeled'] is False
              and obs['atomicFilesystemSnapshot'] is False and obs['exclusiveSourceCustodyRequired'] is True
              and obs['sourceExecution'] is False and isinstance(measured, dict)
              and type(measured['sourceFileCount']) is int
              and measured['sourceFileCount'] == ancestor_snapshot['sourceFileCount'] == 1062659
              and all(measured[k] is True for k in ('fdSafeFullObservationVerified',
                  'exactCoverageVerified', 'unknownHardlinksRejected'))
              and type(measured['explicitCopyGroupsObserved']) is int
              and measured['explicitCopyGroupsObserved'] == 83
              and type(obs['deletedPathCount']) is int
              and obs['deletedPathCount'] == ancestor_snapshot['deletedPathCount']
              and obs['deletedPathsSHA256'] == ancestor_snapshot['deletedPathsSHA256'],
              'Component full source coverage differs')
    binding = build['binaryBinding']; old_binding = ancestor_proof['build']['binaryBinding']
    base.need(isinstance(binding, dict) and set(binding) == set(old_binding)
              and binding['candidateFrameworkSHA256'] != old_binding['candidateFrameworkSHA256']
              and binding['argsGNSHA256'] == ARGS_SHA256 and binding['sourceVersion'] == base.VERSION
              and binding['architecture'] == binding['targetArchitecture'] == 'arm64'
              and binding['status'] == 'bound-to-built-candidate', 'Component unsigned identity differs')
    signing = proof['signing']
    base.need(isinstance(signing, dict) and set(signing) == {
        'receiptSHA256', 'buildReceiptSHA256', 'rawInputUnchanged', 'signerIdentity',
        'status', 'signedCodeClosure', 'runtimeTree'}, 'Component signing fields differ')
    base.need(signing['buildReceiptSHA256'] == build['receiptSHA256']
              and signing['rawInputUnchanged'] is True and signing['status'] == 'signed-research-only'
              and signing['signerIdentity'] == ancestor_proof['signing']['signerIdentity'],
              'Component signing lineage differs')
    closure, tree = signing['signedCodeClosure'], signing['runtimeTree']
    base.need(isinstance(closure, dict) and set(closure) == parent.CODE_PATHS
              and all(isinstance(h, str) and base.HEX.fullmatch(h) for h in closure.values())
              and isinstance(tree, dict) and set(tree) == {'digest', 'entries', 'bytes', 'machoCount'}
              and type(tree['machoCount']) is int and tree['machoCount'] == 16
              and type(tree['entries']) is int and tree['entries'] > 16
              and type(tree['bytes']) is int and tree['bytes'] > 0, 'Component signed closure differs')
    development = proof['developmentObservation']
    base.need(isinstance(development, dict) and set(development) == {'path', 'sha256'}
              and development['path'] == 'docs/evidence/component-completion-development.json',
              'Component development evidence path differs')
    report = base.bound(project / 'docs/evidence', 'component-completion-development.json', development['sha256'])
    base.need(report['sourceManifestPins'] == MANIFESTS and report['releaseQualified'] is False
              and report['signedRuntimeTree'] == tree and report['signedCodeClosure'] == closure
              and report['build']['receiptSHA256'] == build['receiptSHA256']
              and report['sourceObservation']['receiptSHA256'] == obs['receiptSHA256']
              and report['sourceObservation']['entriesSHA256'] == measured['entriesSHA256']
              and report['sourceObservation']['changedPaths'] == sorted(specs)
              and report['actualCpp']['positiveCases'] == 4
              and report['actualCpp']['oldImplementationFailures'] == 4
              and report['headed']['status'] == 'observed-scoped-component-operation-completion'
              and report['headed']['routeProved'] is False, 'Component development observation differs')
    for h in (proof['sourceSnapshotSHA256'], build['receiptSHA256'], build['logSHA256'],
              signing['receiptSHA256'], obs['receiptSHA256'], obs['fullInventorySHA256'],
              obs['deletedPathsSHA256'], measured['entriesSHA256'], tree['digest']):
        base.need(isinstance(h, str) and base.HEX.fullmatch(h), 'Invalid component evidence digest')
    base.need(isinstance(proof['limitations'], list) and proof['limitations']
              and all(isinstance(v, str) and v.strip() for v in proof['limitations']),
              'Component proof needs qualification boundaries')
    base.project_value(proof, {})


def verify_contract(project: Path) -> tuple[dict, dict, dict]:
    old_contract, old_snapshot, old_proof = parent.verify_contract(project)
    proof = base.bound(project / 'runtime', PREFIX + '-source-proof.json', PROOF_SHA256)
    verify_projection(project, proof, old_contract, old_snapshot, old_proof)
    snapshot = base.bound(project / 'runtime', PREFIX + '-source-snapshot.json', proof['sourceSnapshotSHA256'])
    expected_snapshot = copy.deepcopy(old_snapshot)
    expected_snapshot.update(argsGN={'relativePath': ARGS_RELATIVE, 'sha256': ARGS_SHA256},
                             entriesSHA256=proof['postbuildObservation']['observation']['entriesSHA256'])
    base.need(snapshot == expected_snapshot, 'Component compact source snapshot differs')
    expected_inputs = {'schemaVersion': 1, 'status': 'source-qualified', 'sourceVariant': VARIANT,
        'chromiumVersion': base.VERSION, 'baseSourceInputManifestSHA256': base.sha256_file(
            project / 'runtime' / (parent.PREFIX + '-source-input-manifest.json')),
        'overlayManifestPins': MANIFESTS, 'sourceDeltaProofSHA256': PROOF_SHA256,
        'sourceSnapshotSHA256': proof['sourceSnapshotSHA256'], 'buildArgsSHA256': ARGS_SHA256,
        'sourceInputsReady': True, 'releaseReady': False}
    inputs = _object(project, 'source-input-manifest')
    base.need(inputs == expected_inputs and type(inputs.get('schemaVersion')) is int,
              'Component source input manifest differs')
    expected = copy.deepcopy(old_contract)
    expected.update(schemaVersion=5, sourceVariant=VARIANT,
        baseSourceContractSHA256=proof['base']['sourceContractSHA256'],
        baseSourceSnapshotSHA256=proof['base']['sourceSnapshotSHA256'],
        baseFullFDObservationSHA256=proof['base']['fullFDObservationSHA256'],
        sourceDeltaProofSHA256=PROOF_SHA256, overlayManifestPins=MANIFESTS,
        sourceSnapshotSHA256=proof['sourceSnapshotSHA256'],
        sourceInputManifestSHA256=base.sha256_file(project / 'runtime' / (PREFIX + '-source-input-manifest.json')))
    contract = _object(project, 'source-contract')
    base.need(contract == expected and type(contract.get('schemaVersion')) is int
              and contract.get('releaseReady') is False, 'Component contract changed predecessor policy')
    return contract, snapshot, proof


def verify_candidate_document(document: dict, *, project_root: Path, source_root: Path | None = None) -> None:
    contract, _, proof = verify_contract(project_root)
    expected = {'schemaVersion': 1, 'sourceVariant': VARIANT, 'status': 'candidate-bound',
        'releaseReady': False, 'targetArchitecture': 'arm64', 'targetChromiumVersion': base.VERSION,
        'sourceContractSHA256': base.sha256_file(project_root / 'runtime' / (PREFIX + '-source-contract.json')),
        'sourceInputManifestSHA256': contract['sourceInputManifestSHA256'],
        'sourceSnapshotSHA256': proof['sourceSnapshotSHA256'], 'binaryBinding': proof['build']['binaryBinding']}
    base.need(document == expected == _object(project_root, 'port-candidate')
              and type(document.get('schemaVersion')) is int and source_root is None,
              'Component candidate differs or requests a new live source scan')


def verify_candidate_lock(lock: dict, *, provenance: dict, project_root: Path) -> None:
    verify_candidate_document(provenance, project_root=project_root)
    expected = copy.deepcopy(base.read_object(project_root / 'runtime' / ('fingerprint-' + parent.PREFIX + '.lock.json'), 'security predecessor lock'))
    expected.update(sourceVariant=VARIANT, sourceContract='runtime/' + PREFIX + '-source-contract.json',
        sourceContractSHA256=provenance['sourceContractSHA256'], sourceProvenance='runtime/' + PREFIX + '-port-candidate.json',
        sourceProvenanceSHA256=base.sha256_file(project_root / 'runtime' / (PREFIX + '-port-candidate.json')))
    expected['binaryBinding']['requiredEvidence'] = expected['sourceProvenance']
    base.need(lock == expected == base.read_object(project_root / 'runtime' / ('fingerprint-' + PREFIX + '.lock.json'), 'component lock')
              and type(lock.get('schemaVersion')) is int, 'Component lock changed predecessor policy')


def verify_unsigned_binary_binding(app: Path, args_gn: Path, document: dict) -> None:
    base.need(args_gn.parent.name == 'NeAntikComponentQA_20261016' and args_gn.name == 'args.gn',
              'Component build args path differs')
    binding = document['binaryBinding']
    for name, key, kind in ((EXE, 'candidateExecutableSHA256', 2), (FRAMEWORK, 'candidateFrameworkSHA256', 6)):
        record = base.observe_regular(app, name, 1024 ** 3)
        base.require_arm64_header(record, kind)
        base.need(record['sha256'] == binding[key], 'Component unsigned runtime changed')
    info = base.observe_regular(app, 'Contents/Info.plist', 1024 * 1024)
    args = base.observe_regular(args_gn.parent, args_gn.name, 1024 * 1024)
    base.need(info['sha256'] == binding['candidateInfoPlistSHA256']
              and args['sha256'] == binding['argsGNSHA256'] == ARGS_SHA256, 'Component Info/args differ')
