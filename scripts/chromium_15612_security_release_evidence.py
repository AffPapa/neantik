"""Additive security source/build/sign lineage; never a release qualification.

The font predecessor remains immutable. This successor authenticates a closed
eight-patch overlay and a fresh postbuild observation of the entire source
tree. Browser behavior, manager admission and Direct delivery are later gates.
"""
from __future__ import annotations

import copy
from pathlib import Path

import chromium_15612_release_evidence as base
import chromium_15612_font_release_evidence as parent
import security_backport_source_delta as delta

VARIANT = 'font-system-security-20261015-v1'
PREFIX = 'chromium-15612-' + VARIANT
ARGS_RELATIVE = 'out/NeAntikSecurityQA_20261016/args.gn'
ARGS_SHA256 = parent.ARGS_SHA256
MANIFEST_SHA256 = 'c35cd893abe1a98284c2146db542c82605c4d0fd7f159f965e0cd88cf0f36cd1'
# Frozen from the actual successful postbuild/sign receipts; never a mock pin.
PROOF_SHA256 = 'ac345eb85cd0f622e2dac36b5d14b43ad28a4d0e4b19ed967815e54f15226dfc'
EXE = 'Contents/MacOS/NeAntik Browser'
FRAMEWORK = ('Contents/Frameworks/NeAntik Browser Framework.framework/Versions/'
             + base.VERSION + '/NeAntik Browser Framework')
_FRAMEWORK_ROOT = FRAMEWORK.rsplit('/', 1)[0] + '/'
CODE_PATHS = frozenset({EXE, FRAMEWORK} | {
    _FRAMEWORK_ROOT + 'Helpers/' + name + '.app/Contents/MacOS/' + name
    for name in ('NeAntik Browser Helper', 'NeAntik Browser Helper (Alerts)',
                 'NeAntik Browser Helper (GPU)', 'NeAntik Browser Helper (Renderer)',
                 'NeAntik Browser Helper (Aperitif)', 'NeAntik Browser Helper (Aperitif Alerts)',
                 'NeAntik Browser Helper (Aperitif GPU)', 'NeAntik Browser Helper (Aperitif Renderer)')
} | {_FRAMEWORK_ROOT + 'Helpers/' + name
     for name in ('app_mode_loader', 'chrome_crashpad_handler', 'web_app_shortcut_copier')}
  | {_FRAMEWORK_ROOT + 'Libraries/' + name
     for name in ('libaperitif.dylib', 'libvk_swiftshader.dylib', 'libvulkan.dylib')})


def _object(project: Path, suffix: str) -> dict:
    return base.read_object(project / 'runtime' / (PREFIX + '-' + suffix + '.json'), suffix)


def verify_projection(project: Path, proof: dict, ancestor_contract: dict,
                      ancestor_snapshot: dict, ancestor_proof: dict) -> None:
    """Check semantics independently of the outer immutable proof hash."""
    base.need(isinstance(proof, dict) and set(proof) == {
        'schemaVersion', 'kind', 'sourceVariant', 'targetChromiumVersion',
        'releaseReady', 'base', 'securityPatchManifestSHA256', 'changes',
        'sourceSnapshotSHA256', 'postbuildObservation', 'build', 'signing',
        'limitations'}, 'Security source proof fields differ')
    base.need(type(proof['schemaVersion']) is int and proof['schemaVersion'] == 1
              and proof['kind'] == 'security-backport-executed-build-and-postbuild-source-proof'
              and proof['sourceVariant'] == VARIANT
              and proof['targetChromiumVersion'] == base.VERSION
              and proof['releaseReady'] is False, 'Security source proof identity differs')
    runtime = project / 'runtime'
    expected_base = {
        'sourceContractSHA256': base.sha256_file(runtime / (parent.PREFIX + '-source-contract.json')),
        'sourceSnapshotSHA256': base.sha256_file(runtime / (parent.PREFIX + '-source-snapshot.json')),
        'sourceDeltaProofSHA256': parent.PROOF_SHA256,
        'fullFDObservationSHA256': ancestor_proof['postbuildObservation']['receiptSHA256'],
        'fullInventorySHA256': ancestor_proof['postbuildObservation']['fullInventorySHA256'],
    }
    base.need(proof['base'] == expected_base, 'Security predecessor differs')
    base.need(proof['securityPatchManifestSHA256'] == MANIFEST_SHA256,
              'Security patch manifest differs')
    specs = delta.load_inputs(project, MANIFEST_SHA256)
    build = proof['build']
    base.need(isinstance(build, dict) and set(build) == {
        'receiptSHA256', 'logSHA256', 'target', 'jobs', 'exitCode', 'argsSHA256',
        'sourcePostimages', 'sourcePostimagesUnchanged', 'sourceManifestUnchanged',
        'oldRuntimeAndArgsUnchanged', 'toolsUnchanged', 'binaryBinding', 'toolHashes'},
        'Security build fields differ')
    base.need(build['target'] == 'chrome' and type(build['jobs']) is int
              and build['jobs'] == 2 and type(build['exitCode']) is int
              and build['exitCode'] == 0 and build['argsSHA256'] == ARGS_SHA256
              and all(build[k] is True for k in (
                  'sourcePostimagesUnchanged', 'sourceManifestUnchanged',
                  'oldRuntimeAndArgsUnchanged', 'toolsUnchanged')),
              'Security build did not preserve its inputs')
    base.need(isinstance(build['toolHashes'], dict) and set(build['toolHashes']) == {
        'buildtools/mac/gn', 'third_party/llvm-build/Release+Asserts/bin/clang',
        'third_party/ninja/ninja', 'third_party/rust-toolchain/bin/bindgen',
        'third_party/rust-toolchain/bin/cc_bindings_from_rs',
        'third_party/rust-toolchain/bin/rustc'}
        and all(isinstance(h, str) and base.HEX.fullmatch(h)
                for h in build['toolHashes'].values()), 'Security native tool closure differs')
    postimages = build['sourcePostimages']
    fonts = ancestor_proof['build']['sourcePostimages']
    base.need(isinstance(postimages, dict) and set(postimages) == set(specs) | set(fonts)
              and not set(specs).intersection(fonts)
              and {n: postimages[n] for n in fonts} == fonts,
              'Security build changed the font predecessor or omitted inputs')
    delta.verify_projection(proof['changes'], specs, {n: postimages[n] for n in specs})
    observation = proof['postbuildObservation']
    base.need(isinstance(observation, dict) and set(observation) == {
        'receiptSHA256', 'fullInventorySHA256', 'ancestorFullSHA256',
        'historicalBuildObservationRelabeled', 'atomicFilesystemSnapshot',
        'exclusiveSourceCustodyRequired', 'sourceExecution', 'observation',
        'deletedPathCount', 'deletedPathsSHA256'}, 'Security observation fields differ')
    measured = observation['observation']
    base.need(observation['ancestorFullSHA256'] == expected_base['fullInventorySHA256']
              and observation['historicalBuildObservationRelabeled'] is False
              and observation['atomicFilesystemSnapshot'] is False
              and observation['exclusiveSourceCustodyRequired'] is True
              and observation['sourceExecution'] is False
              and isinstance(measured, dict)
              and measured['sourceFileCount'] == ancestor_snapshot['sourceFileCount'] + 4 == 1062659
              and type(measured['sourceFileCount']) is int
              and all(measured[k] is True for k in (
                  'fdSafeFullObservationVerified', 'exactCoverageVerified',
                  'unknownHardlinksRejected'))
              and type(measured['explicitCopyGroupsObserved']) is int
              and measured['explicitCopyGroupsObserved'] == 83
              and type(observation['deletedPathCount']) is int
              and observation['deletedPathCount'] == ancestor_snapshot['deletedPathCount'] + 2,
              'Security whole-source observation is incomplete')
    binding = build['binaryBinding']
    old = ancestor_proof['build']['binaryBinding']
    base.need(isinstance(binding, dict) and set(binding) == set(old)
              and binding['candidateFrameworkSHA256'] != old['candidateFrameworkSHA256']
              and binding['argsGNSHA256'] == ARGS_SHA256
              and binding['sourceVersion'] == base.VERSION
              and binding['architecture'] == binding['targetArchitecture'] == 'arm64'
              and binding['status'] == 'bound-to-built-candidate', 'Security unsigned output identity differs')
    signing = proof['signing']
    base.need(isinstance(signing, dict) and set(signing) == {
        'receiptSHA256', 'buildReceiptSHA256', 'rawInputUnchanged', 'signerIdentity',
        'status', 'signedCodeClosure', 'runtimeTree'}, 'Security signing fields differ')
    base.need(signing['buildReceiptSHA256'] == build['receiptSHA256']
              and signing['rawInputUnchanged'] is True
              and signing['signerIdentity'] == '474F7C78F33EE324C24F6F5AE0443EB713E85E60'
              and signing['status'] == 'signed-research-only', 'Security signing lineage differs')
    closure = signing['signedCodeClosure']
    tree = signing['runtimeTree']
    base.need(isinstance(closure, dict) and set(closure) == CODE_PATHS
              and all(isinstance(n, str) and n.startswith('Contents/')
                      and all(p not in ('', '.', '..') for p in n.split('/'))
                      and isinstance(h, str) and base.HEX.fullmatch(h)
                      for n, h in closure.items())
              and isinstance(tree, dict) and set(tree) == {'digest', 'entries', 'bytes', 'machoCount'}
              and type(tree['machoCount']) is int and tree['machoCount'] == 16
              and type(tree['entries']) is int and tree['entries'] > 16
              and type(tree['bytes']) is int and tree['bytes'] > 0
              and isinstance(tree['digest'], str) and base.HEX.fullmatch(tree['digest']),
              'Security signing closure is incomplete')
    for value in (build['receiptSHA256'], build['logSHA256'], signing['receiptSHA256'],
                  observation['receiptSHA256'], observation['fullInventorySHA256'],
                  observation['deletedPathsSHA256'], measured['entriesSHA256'],
                  proof['sourceSnapshotSHA256']):
        base.need(isinstance(value, str) and base.HEX.fullmatch(value), 'Invalid security evidence digest')
    base.need(isinstance(proof['limitations'], list) and proof['limitations']
              and all(isinstance(v, str) and v.strip() for v in proof['limitations']),
              'Security proof needs its qualification boundaries')
    base.project_value(proof, {})


def verify_contract(project: Path) -> tuple[dict, dict, dict]:
    ancestor_contract, ancestor_snapshot, ancestor_proof = parent.verify_contract(project)
    proof = base.bound(project / 'runtime', PREFIX + '-source-proof.json', PROOF_SHA256)
    verify_projection(project, proof, ancestor_contract, ancestor_snapshot, ancestor_proof)
    snapshot = base.bound(project / 'runtime', PREFIX + '-source-snapshot.json', proof['sourceSnapshotSHA256'])
    expected_snapshot = copy.deepcopy(ancestor_snapshot)
    observation = proof['postbuildObservation']
    expected_snapshot.update(argsGN={'relativePath': ARGS_RELATIVE, 'sha256': ARGS_SHA256},
        sourceFileCount=1062659, entriesSHA256=observation['observation']['entriesSHA256'],
        deletedPathCount=observation['deletedPathCount'], deletedPathsSHA256=observation['deletedPathsSHA256'])
    base.need(snapshot == expected_snapshot, 'Security compact snapshot differs')
    inputs = _object(project, 'source-input-manifest')
    expected_inputs = {
        'schemaVersion': 1, 'status': 'source-qualified', 'sourceVariant': VARIANT,
        'chromiumVersion': base.VERSION,
        'baseSourceInputManifestSHA256': base.sha256_file(project / 'runtime' / (parent.PREFIX + '-source-input-manifest.json')),
        'securityPatchManifestSHA256': MANIFEST_SHA256, 'sourceDeltaProofSHA256': PROOF_SHA256,
        'sourceSnapshotSHA256': proof['sourceSnapshotSHA256'], 'buildArgsSHA256': ARGS_SHA256,
        'sourceInputsReady': True, 'releaseReady': False}
    base.need(inputs == expected_inputs and type(inputs.get('schemaVersion')) is int
              and inputs.get('sourceInputsReady') is True and inputs.get('releaseReady') is False,
              'Security source input manifest differs')
    expected_contract = copy.deepcopy(ancestor_contract)
    expected_contract.update(schemaVersion=4, sourceVariant=VARIANT,
        baseSourceContractSHA256=proof['base']['sourceContractSHA256'],
        baseSourceSnapshotSHA256=proof['base']['sourceSnapshotSHA256'],
        baseFullFDObservationSHA256=proof['base']['fullFDObservationSHA256'],
        sourceDeltaProofSHA256=PROOF_SHA256, securityPatchManifestSHA256=MANIFEST_SHA256,
        sourceSnapshotSHA256=proof['sourceSnapshotSHA256'],
        sourceInputManifestSHA256=base.sha256_file(project / 'runtime' / (PREFIX + '-source-input-manifest.json')))
    contract = _object(project, 'source-contract')
    base.need(contract == expected_contract and type(contract.get('schemaVersion')) is int
              and contract.get('releaseReady') is False,
              'Security contract changed unrelated predecessor policy')
    return contract, snapshot, proof


def verify_candidate_document(document: dict, *, project_root: Path,
                              source_root: Path | None = None) -> None:
    contract, _, proof = verify_contract(project_root)
    expected = {'schemaVersion': 1, 'sourceVariant': VARIANT, 'status': 'candidate-bound',
        'releaseReady': False, 'targetArchitecture': 'arm64', 'targetChromiumVersion': base.VERSION,
        'sourceContractSHA256': base.sha256_file(project_root / 'runtime' / (PREFIX + '-source-contract.json')),
        'sourceInputManifestSHA256': contract['sourceInputManifestSHA256'],
        'sourceSnapshotSHA256': proof['sourceSnapshotSHA256'], 'binaryBinding': proof['build']['binaryBinding']}
    base.need(document == expected == _object(project_root, 'port-candidate')
              and type(document.get('schemaVersion')) is int and document.get('releaseReady') is False,
              'Security candidate differs')
    base.need(source_root is None, 'Security source uses its preserved FD observation, not a new live scan')


def verify_candidate_lock(lock: dict, *, provenance: dict, project_root: Path) -> None:
    verify_candidate_document(provenance, project_root=project_root)
    runtime = project_root / 'runtime'
    expected = copy.deepcopy(base.read_object(runtime / ('fingerprint-' + parent.PREFIX + '.lock.json'), 'font predecessor lock'))
    expected.update(sourceVariant=VARIANT, sourceContract='runtime/' + PREFIX + '-source-contract.json',
        sourceContractSHA256=provenance['sourceContractSHA256'],
        sourceProvenance='runtime/' + PREFIX + '-port-candidate.json',
        sourceProvenanceSHA256=base.sha256_file(runtime / (PREFIX + '-port-candidate.json')))
    expected['binaryBinding']['requiredEvidence'] = expected['sourceProvenance']
    base.need(lock == expected == base.read_object(runtime / ('fingerprint-' + PREFIX + '.lock.json'), 'security lock')
              and type(lock.get('schemaVersion')) is int and lock.get('releaseReady') is False,
              'Security lock changed unrelated licensing/verification policy')


def verify_unsigned_binary_binding(app: Path, args_gn: Path, document: dict) -> None:
    base.need(args_gn.parent.name == 'NeAntikSecurityQA_20261016' and args_gn.name == 'args.gn',
              'Security build args path differs')
    binding = document['binaryBinding']
    for relative, key, kind in ((EXE, 'candidateExecutableSHA256', 2),
                                (FRAMEWORK, 'candidateFrameworkSHA256', 6)):
        record = base.observe_regular(app, relative, 1024 ** 3)
        base.require_arm64_header(record, kind)
        base.need(record['sha256'] == binding[key], 'Security unsigned runtime changed')
    info = base.observe_regular(app, 'Contents/Info.plist', 1024 * 1024)
    args = base.observe_regular(args_gn.parent, args_gn.name, 1024 * 1024)
    base.need(info['sha256'] == binding['candidateInfoPlistSHA256']
              and args['sha256'] == binding['argsGNSHA256'] == ARGS_SHA256,
              'Security runtime Info/args binding differs')
