"""Additive M156 font source proof. Historical final9 inputs stay immutable.

The executed build and later full FD observation are different events. Neither
this source contract nor identity dispatch grants signed-release authority.
"""
from __future__ import annotations
import copy
from pathlib import Path
import chromium_15612_release_evidence as base
from chromium_15612_variant import FONT_PREFIX as PREFIX, FONT_VARIANT as VARIANT

PROOF_SHA256 = '8a86c02e8727790658626c501219a3c2f5b384372eee7e1e1d3c524a462844dc'
ARGS_RELATIVE = 'out/NeAntikFontSkiaQA_20261016a/args.gn'
ARGS_SHA256 = '428054a30abeb212aa3784f524bb27ef4bc0068ab7ebef149866b2b8bff30a3c'
MANIFESTS = ('chromium-host-font-policy.json', 'chromium-font-witness.json',
             'chromium-font-cleanup.json', 'chromium-font-cleanup-cstring.json',
             'chromium-font-generic-defaults.json', 'chromium-font-variations.json')
BASE_FD_SHA256 = 'd6836d97a7a24d370663976063516306bfc646c826149f579a319fdb5578722c'
BASE_FULL_SHA256 = '20bf2bbd12a7dbc146f02b6de8dc42161bef1e9a9d2dd1ac155032e3e3a57446'


def _object(project: Path, suffix: str) -> dict:
    return base.read_object(project / 'runtime' / (PREFIX + '-' + suffix + '.json'), suffix)


def _record(record, name: str) -> None:
    base.need(isinstance(record, dict) and set(record) == {'kind', 'path', 'mode', 'sizeBytes', 'sha256'} and
              record['kind'] == 'file' and record['path'] == name and
              type(record['mode']) is int and record['mode'] in (0o600, 0o644, 0o755) and
              type(record['sizeBytes']) is int and 0 < record['sizeBytes'] <= 4 * 1024 * 1024 and
              isinstance(record['sha256'], str) and base.HEX.fullmatch(record['sha256']),
              'Invalid font overlay source record')


def verify_projection(project: Path, proof: dict, ancestor_contract: dict, ancestor_snapshot: dict) -> None:
    """Semantic controls also run on deliberately broken in-memory projections."""
    expected_keys = {'schemaVersion', 'kind', 'sourceVariant', 'targetChromiumVersion', 'releaseReady', 'base',
                     'sourceContracts', 'changes', 'qaOwnedInputs', 'sourceSnapshotSHA256',
                     'postbuildObservation', 'build', 'signing', 'limitations'}
    base.need(set(proof) == expected_keys and type(proof['schemaVersion']) is int and proof['schemaVersion'] == 1 and
              proof['kind'] == 'font-system-v1-executed-build-and-postbuild-source-proof' and
              proof['sourceVariant'] == VARIANT and proof['targetChromiumVersion'] == base.VERSION and
              proof['releaseReady'] is False, 'Font source proof identity')
    expected_base = {'sourceContractSHA256': base.sha256_file(project / 'runtime/chromium-15612-source-contract.json'),
                     'sourceSnapshotSHA256': base.sha256_file(project / 'runtime/chromium-15612-source-snapshot.json'),
                     'fullFDObservationSHA256': BASE_FD_SHA256, 'fullInventorySHA256': BASE_FULL_SHA256}
    base.need(proof['base'] == expected_base, 'Font source proof ancestor mismatch')
    changes = proof['changes']
    base.need(isinstance(changes, list) and len(changes) == 29, 'Closed font overlay required')
    records = {}
    for item in changes:
        base.need(isinstance(item, dict) and set(item) == {'path', 'before', 'after'}, 'Font delta fields differ')
        name = item['path']
        base.need(isinstance(name, str) and name and not name.startswith('/') and '\\' not in name and
                  all(p not in ('', '.', '..') for p in name.split('/')) and name not in records,
                  'Unsafe or duplicate font source path')
        _record(item['after'], name)
        if item['before'] is not None:
            _record(item['before'], name)
        records[name] = item
    base.need(list(records) == sorted(records), 'Font overlay must be sorted')
    current = {name: item['before']['sha256'] if item['before'] else None for name, item in records.items()}
    touched = set()
    contracts = proof['sourceContracts']
    base.need(isinstance(contracts, dict) and set(contracts) == set(MANIFESTS), 'Exact six source contracts required')
    policy = project / 'runtime/font-policy-v1'
    final_source = {}
    for index, name in enumerate(MANIFESTS):
        manifest = base.bound(policy, name, contracts[name])
        patch = manifest.get('patchFile')
        base.need(isinstance(patch, str) and '/' not in patch and patch.endswith('.patch'), 'Unsafe font patch name')
        base.need(base.sha256_file(base.safe_relative_regular(policy, patch)) == manifest['patchSHA256'], 'Font patch drift')
        if index:
            base.need(manifest['parentManifest'] == MANIFESTS[index - 1] and
                      manifest['parentManifestSHA256'] == contracts[MANIFESTS[index - 1]], 'Font layer parent mismatch')
        else:
            base.need(manifest['parentSourceContractSHA256'] == expected_base['sourceContractSHA256'], 'Font base contract mismatch')
        for file in manifest['files']:
            name = file['path']
            base.need(name in records and current[name] == file['preimageSHA256'], 'Font source preimage gap')
            base.need(records[name]['after']['mode'] == 0o644, 'Font source mode differs')
            current[name] = file['postimageSHA256']; touched.add(name); final_source[name] = current[name]
        for asset in manifest.get('fixedAssets', []):
            name = asset['path']
            base.need(name in records and current[name] is None and
                      records[name]['after']['mode'] == 0o600 and records[name]['after']['sizeBytes'] == asset['bytes'] and
                      base.sha256_file(base.safe_relative_regular(policy, asset['source'])) == asset['sha256'],
                      'Font asset provenance or metadata differs')
            current[name] = asset['sha256']; touched.add(name)
    qa = proof['qaOwnedInputs']
    qa_names = {'runtime/font-policy-v1/native-probe/BUILD.gn', 'runtime/font-policy-v1/native-probe/neantik_font_probe.mm'}
    base.need(isinstance(qa, dict) and set(qa) == qa_names, 'Closed own QA source inputs required')
    for source, digest in qa.items():
        name = 'tools/neantik_font_probe/' + Path(source).name
        base.need(name in records and current[name] is None and records[name]['after']['mode'] == 0o644 and
                  base.sha256_file(base.safe_relative_regular(project, source)) == digest, 'Own QA input drift')
        current[name] = digest; touched.add(name)
    base.need(touched == set(records) and len(final_source) == 25 and
              all(current[n] == r['after']['sha256'] for n, r in records.items()), 'Unrelated or incomplete source overlay')
    observation = proof['postbuildObservation']
    measured = observation['observation']
    base.need(observation['historicalBuildObservationRelabeled'] is False and observation['atomicFilesystemSnapshot'] is False and
              observation['exclusiveSourceCustodyRequired'] is True and observation['sourceExecution'] is False and
              measured['sourceFileCount'] == ancestor_snapshot['sourceFileCount'] + sum(r['before'] is None for r in records.values()) and
              measured['sourceFileCount'] == 1062655 and measured['fdSafeFullObservationVerified'] is True and
              measured['exactCoverageVerified'] is True and measured['explicitCopyGroupsObserved'] == 83 and
              measured['unknownHardlinksRejected'] is True, 'Postbuild content observation incomplete')
    build = proof['build']
    base.need(build['target'] == 'chrome' and type(build['jobs']) is int and build['jobs'] == 2 and
              build['argsSHA256'] == ARGS_SHA256 and build['sourcePostimages'] == final_source and
              all(build[k] is True for k in ('sourcePostimagesUnchanged', 'contractsUnchanged',
                                            'oldRuntimeObjectsArgsAndSignedClosureUnchanged')), 'Executed font build binding mismatch')
    binding = build['binaryBinding']
    old = base.read_object(project / 'runtime/chromium-15612-port-candidate.json', 'ancestor candidate')['binaryBinding']
    base.need(set(binding) == set(old) and binding['candidateFrameworkSHA256'] != old['candidateFrameworkSHA256'] and
              binding['argsGNSHA256'] == ARGS_SHA256 and binding['sourceVersion'] == base.VERSION and
              binding['targetArchitecture'] == 'arm64' and binding['status'] == 'bound-to-built-candidate', 'Font unsigned output identity')
    signing = proof['signing']
    base.need(signing['buildReceiptSHA256'] == build['receiptSHA256'] and signing['rawInputUnchanged'] is True and
              signing['signerIdentity'] == '474F7C78F33EE324C24F6F5AE0443EB713E85E60' and
              signing['status'] == 'signed-research-only', 'Font signing lineage mismatch')
    headed = base.read_object(project / 'docs/evidence/font-variation-headed-development.json', 'font headed scope')
    base.need(signing['signedExecutableSHA256'] == headed['runtime']['executableSHA256'] and
              signing['signedFrameworkSHA256'] == headed['runtime']['frameworkSHA256'] and
              signing['runtimeTree'] == headed['runtimeTree'], 'Font source/signing and headed scope disagree')

    base.project_value(proof, {})


def verify_contract(project: Path) -> tuple[dict, dict, dict]:
    ancestor_contract, ancestor_snapshot = base.verify_contract(project)
    runtime = project / 'runtime'
    proof = base.bound(runtime, PREFIX + '-source-proof.json', PROOF_SHA256)
    verify_projection(project, proof, ancestor_contract, ancestor_snapshot)
    snapshot = base.bound(runtime, PREFIX + '-source-snapshot.json', proof['sourceSnapshotSHA256'])
    expected_snapshot = copy.deepcopy(ancestor_snapshot)
    expected_snapshot.update(argsGN={'relativePath': ARGS_RELATIVE, 'sha256': ARGS_SHA256},
                             entriesSHA256=proof['postbuildObservation']['observation']['entriesSHA256'], sourceFileCount=1062655)
    base.need(snapshot == expected_snapshot and type(snapshot['sourceFileCount']) is int, 'Font source snapshot differs')
    inputs = _object(project, 'source-input-manifest')
    expected_inputs = {'schemaVersion': 1, 'status': 'source-qualified', 'sourceVariant': VARIANT, 'chromiumVersion': base.VERSION,
                       'baseSourceInputManifestSHA256': base.sha256_file(runtime / 'chromium-15612-source-input-manifest.json'),
                       'sourceDeltaProofSHA256': PROOF_SHA256, 'sourceSnapshotSHA256': proof['sourceSnapshotSHA256'],
                       'buildArgsSHA256': ARGS_SHA256, 'sourceInputsReady': True, 'releaseReady': False}
    base.need(inputs == expected_inputs and type(inputs['schemaVersion']) is int and inputs['sourceInputsReady'] is True and
              inputs['releaseReady'] is False, 'Font source input manifest differs')
    expected_contract = copy.deepcopy(ancestor_contract)
    expected_contract.update(schemaVersion=3, sourceVariant=VARIANT,
        baseSourceContractSHA256=proof['base']['sourceContractSHA256'], baseSourceSnapshotSHA256=proof['base']['sourceSnapshotSHA256'],
        baseFullFDObservationSHA256=BASE_FD_SHA256, sourceDeltaProofSHA256=PROOF_SHA256,
        sourceSnapshotSHA256=proof['sourceSnapshotSHA256'], sourceInputManifestSHA256=base.sha256_file(runtime / (PREFIX + '-source-input-manifest.json')),
        buildArgsSHA256=ARGS_SHA256)
    contract = _object(project, 'source-contract')
    base.need(contract == expected_contract and type(contract['schemaVersion']) is int and contract['releaseReady'] is False,
              'Font contract changed unrelated ancestor policy or bindings')
    return contract, snapshot, proof


def verify_candidate_document(document: dict, *, project_root: Path, source_root: Path | None = None) -> None:
    contract, snapshot, proof = verify_contract(project_root)
    runtime = project_root / 'runtime'
    expected = {'schemaVersion': 1, 'sourceVariant': VARIANT, 'status': 'candidate-bound', 'releaseReady': False,
                'targetArchitecture': 'arm64', 'targetChromiumVersion': base.VERSION,
                'sourceContractSHA256': base.sha256_file(runtime / (PREFIX + '-source-contract.json')),
                'sourceInputManifestSHA256': contract['sourceInputManifestSHA256'], 'sourceSnapshotSHA256': proof['sourceSnapshotSHA256'],
                'binaryBinding': proof['build']['binaryBinding']}
    base.need(document == expected and document == _object(project_root, 'port-candidate') and
              type(document['schemaVersion']) is int and document['releaseReady'] is False, 'Font candidate differs from exact source proof')
    if source_root is not None:
        raise base.M15612EvidenceError('Font source uses its explicit postbuild FD proof; this call cannot claim a new live observation')


def verify_candidate_lock(lock: dict, *, provenance: dict, project_root: Path) -> None:
    verify_candidate_document(provenance, project_root=project_root)
    runtime = project_root / 'runtime'
    expected = copy.deepcopy(base.read_object(runtime / 'fingerprint-chromium-15612.lock.json', 'ancestor lock'))
    expected.update(sourceVariant=VARIANT, sourceContract='runtime/' + PREFIX + '-source-contract.json',
                    sourceContractSHA256=provenance['sourceContractSHA256'], sourceProvenance='runtime/' + PREFIX + '-port-candidate.json',
                    sourceProvenanceSHA256=base.sha256_file(runtime / (PREFIX + '-port-candidate.json')))
    expected['binaryBinding']['requiredEvidence'] = expected['sourceProvenance']
    canonical = base.read_object(runtime / ('fingerprint-' + PREFIX + '.lock.json'), 'font lock')
    base.need(lock == expected == canonical and type(lock['schemaVersion']) is int and lock['releaseReady'] is False,
              'Font lock changed unrelated upstream/licensing/pending verification policy')
    base.project_value(lock, {})


def verify_unsigned_binary_binding(app: Path, args_gn: Path, document: dict) -> None:
    base.need(args_gn.parent.name == 'NeAntikFontSkiaQA_20261016a' and args_gn.name == 'args.gn', 'Font build args path mismatch')
    binding = document['binaryBinding']
    paths = [('Contents/MacOS/NeAntik Browser', 'candidateExecutableSHA256', 2),
             ('Contents/Frameworks/NeAntik Browser Framework.framework/Versions/' + base.VERSION + '/NeAntik Browser Framework',
              'candidateFrameworkSHA256', 6)]
    for relative, key, kind in paths:
        record = base.observe_regular(app, relative, 1024 ** 3)
        base.require_arm64_header(record, kind)
        base.need(record['sha256'] == binding[key], 'Font unsigned runtime changed')
    info = base.observe_regular(app, 'Contents/Info.plist', 1024 * 1024)
    args = base.observe_regular(args_gn.parent, args_gn.name, 1024 * 1024)
    base.need(info['sha256'] == binding['candidateInfoPlistSHA256'] and args['sha256'] == binding['argsGNSHA256'] == ARGS_SHA256,
              'Font runtime Info/args binding differs')


if __name__ == '__main__':
    import argparse
    import json
    parser = argparse.ArgumentParser(description='Verify the reviewed additive font source contract; no build or browser launch.')
    parser.add_argument('--project-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--runtime-app', type=Path)
    parser.add_argument('--args-gn', type=Path)
    args = parser.parse_args()
    if (args.runtime_app is None) != (args.args_gn is None):
        parser.error('--runtime-app and --args-gn must be supplied together')
    try:
        candidate = _object(args.project_root, 'port-candidate')
        lock = base.read_object(args.project_root / 'runtime' / ('fingerprint-' + PREFIX + '.lock.json'), 'font lock')
        verify_candidate_lock(lock, provenance=candidate, project_root=args.project_root)
        if args.runtime_app is not None:
            verify_unsigned_binary_binding(args.runtime_app, args.args_gn, candidate)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, 'M156 font source verification refused: ' + str(error) + '\n')
    print(json.dumps({'status': 'source-qualified', 'sourceVariant': VARIANT,
                      'preservedPostbuildProof': True, 'freshSourceScan': False,
                      'actualUnsignedOutputCompared': args.runtime_app is not None,
                      'actualBrowserLaunched': False, 'releaseQualified': False}))
