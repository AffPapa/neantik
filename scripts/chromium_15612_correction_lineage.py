#!/usr/bin/env python3
"""Check retained M156 correction image order, not actual apply/build/runtime.

Authenticated receipts and patch bytes are required from the caller. This
does not execute source/patches, reobserve source, qualify an application or
replace independent pruning/package/generation/whole-source gates.
"""
from __future__ import annotations
import hashlib
from typing import Any
from chromium_15612_generated_cache import need, relative_path, HASH
from chromium_15612_input_lineage import verify_lineage
from chromium_15612_postbuild import ARGS_SHA256, canonical_digest

CORRECTIONS = (
    ('m156-dpr-apply-receipt.json', '645ba0ef2dc8bb91e3547f003ceda136cdc86e6960bd7ecf230fab8bdd6fc1fc'),
    ('m156-gn-mode0-correction.json', '8501908f92cceb20b9ac2eefacc3643aa71479c8418afff881f532d5de6b948f'),
    ('m156-gn-pdf-correction.json', 'ff8f9565a46dfc0cd8ef79c2fd379f2c273f38a91219d8ca704f172e8e81383f'),
    ('m156-enterprise-referrer-correction.json', 'ac4e7d04ba1ff40c5034d6e246c7b3ed70af3ae42d022427f9f58a7ba53fbd0c'),
    ('m156-bidi-correction.json', '1ad33c59b84b3738de0c6f4ed963ca6705c46401408bbe7fc31b34b1e51aa33c'),
    ('native-devtools-typescript-correction.json', 'bbb8c960855b77165545651bf667fa132f7dfc19aff6edf35bd05706368c0c73'),
    ('native-thinlto-worker-cap-correction.json', '54ade99fa16e0a9105d1597779128749b90750f4f8db37a1f281388ac4bfd41a'),
    ('native-version-info-header-dependency-correction.json', 'b69141aa99b5342288e9fa780c9ee55c841e318d774c1e048b2253e4069b37d7'),
    ('native-v8-interpreter-scope-declaration-correction.json', '8f774fa4d2c1aa1481174594dd481abbdd6aed148d7ee4defc892653edb81408'),
)
HEADER = 'components/ungoogled/neantik_device_scale_factor.h'
PRUNING_SHA256 = 'af9f3cb8073214a0ce634f915c7ce90708bd30feb8c8cdb134dc95fcb9b6e3b5'
ORIGINAL_PRUNING_SHA256 = '6ce85bb896bfd45c55ceb032c4dd843e4e3ccdcc42a2dbab4a7fa6ec22c7f5fb'
GENERATED = {'build/util/LASTCHANGE', 'gpu/config/gpu_lists_version.h',
             'skia/ext/skia_commit_hash.h', 'gpu/webgpu/DAWN_VERSION', 'gpu/webgpu/dawn_commit_hash.h'}


def images(value: Any, maximum: int = 20_000) -> dict[str, str | None]:
    need(isinstance(value, dict) and 0 < len(value) <= maximum, 'Image map missing or oversized')
    for name, digest in value.items():
        relative_path(name)
        need(digest is None or (isinstance(digest, str) and HASH.fullmatch(digest)),
             'Invalid correction source digest')
    return value


def advance(current: dict[str, str | None], pre: dict[str, str | None],
            post: dict[str, str | None], *, unknown_allowed: bool = False) -> int:
    """Known predecessor mismatch always fails, including null vs absent."""
    images(pre); images(post)
    need(set(pre) == set(post), 'Correction image path coverage differs')
    unknown = 0
    for name, digest in pre.items():
        if name in current:
            need(current[name] == digest, 'Broken subsequent source preimage chain')
        else:
            need(unknown_allowed, 'Unanchored correction preimage')
            unknown += 1
    current.update(post)
    return unknown


def patch_paths(raw: bytes) -> set[str]:
    need(isinstance(raw, bytes) and 0 < len(raw) <= 4*1024*1024, 'Bounded correction patch required')
    paths: set[str] = set()
    before = None
    for line in raw.decode('utf8').splitlines():
        if line.startswith('--- '):
            need(before is None, 'Incomplete correction patch header')
            before = line[4:].split('\t')[0]
            need(before == '/dev/null' or before.startswith('a/'), 'Unexpected old patch prefix')
        elif line.startswith('+++ '):
            need(before is not None, 'Unpaired correction patch header')
            after = line[4:].split('\t')[0]
            need(after.startswith('b/'), 'Unexpected correction deletion or new prefix')
            name = relative_path(after[2:])
            need(before == '/dev/null' or before[2:] == name, 'Correction renames unsupported')
            need(name not in paths, 'Duplicate correction patch target')
            paths.add(name); before = None
    need(before is None and paths, 'Correction patch has no complete targets')
    return paths


def verify_chain(documents: dict[str, dict[str, Any]], *, pristine: dict[str, str],
                 new_header_absence_observed: bool, patches: dict[str, bytes],
                 original_pruning: bytes, reviewed_pruning: bytes) -> dict[str, Any]:
    preceding = verify_lineage(documents)
    current = dict(preceding['stageReplayPostimages'])
    need(len(current) == 805 and len(pristine) == 11 and new_header_absence_observed is True,
         'Exact preceding images/pristine/absence observations required')
    for name, digest in images(pristine, 11).items():
        need(digest is not None and (name not in current or current[name] == digest),
             'Pristine anchor disagrees with preceding replay')
        current[name] = digest
    need(HEADER not in current, 'New header was already introduced')
    current[HEADER] = None
    payload = lambda name: documents[name]['payload']
    operations = []

    def apply_patch(index: int, record: dict[str, Any]) -> None:
        name, expected = CORRECTIONS[index]
        need(record.get('patchSHA256') == expected and payload(name).get('releaseReady') is False,
             'Correction patch identity or unqualified status differs')
        raw = patches[name]
        need(hashlib.sha256(raw).hexdigest() == expected and
             patch_paths(raw) == set(record['preimages']), 'Correction patch bytes/targets differ')
        advance(current, record['preimages'], record['postimages'])
        need(record['preimages'] != record['postimages'], 'Correction declares no source change')
        operations.append({'kind': 'patch', 'receipt': name, 'patchSHA256': expected,
                           'paths': sorted(record['postimages'])})

    dpr = payload(CORRECTIONS[0][0])
    roots = dpr['appliedRoots']
    need(len(roots) == 2 and [item['label'] for item in roots] == ['shadow', 'full-source'] and
         roots[0]['preimages'] == roots[1]['preimages'] and roots[0]['postimages'] == roots[1]['postimages'] and
         len(roots[1]['preimages']) == 9, 'DPR shadow/full source images differ')
    apply_patch(0, {**roots[1], 'patchSHA256': dpr['patchSHA256']})
    native = payload('m156-native-inputs-receipt.json')
    need(native['releaseReady'] is False and native['status'] == 'prepared-native-inputs-unqualified' and
         native['dprReceiptSHA256'] == documents[CORRECTIONS[0][0]]['originalReceiptSHA256'] and
         native['argsGN']['sha256'] == native['argsGN']['baseM155SHA256'] == ARGS_SHA256,
         'Native preparation/args ancestry differs')
    pruning = native['pruning']
    need(hashlib.sha256(original_pruning).hexdigest() == pruning['originalSHA256'] == ORIGINAL_PRUNING_SHA256 and
         hashlib.sha256(reviewed_pruning).hexdigest() == pruning['reviewedSHA256'] == PRUNING_SHA256,
         'Pruning schedules differ')
    original = [relative_path(name) for name in original_pruning.decode().splitlines() if name]
    reviewed = [relative_path(name) for name in reviewed_pruning.decode().splitlines() if name]
    preserved = pruning['preserved']; missing = pruning['missingBeforeApply']; protected = pruning['protected']
    need(len(original) == len(set(original)) and len(reviewed) == 13832 and len(set(reviewed)) == 13832 and
         [item['path'] for item in preserved] == reviewed and len(missing) == 154 and len(set(missing)) == 154 and
         set(protected) == {'components/safe_browsing/core/common/safe_browsing_prefs.cc',
                            'components/safe_browsing/core/common/safe_browsing_prefs.h'} and
         set(original) == set(reviewed) | set(missing) | set(protected) and
         not(set(reviewed) & set(missing) or set(reviewed) & set(protected) or set(missing) & set(protected)),
         'Literal pruning coverage differs')
    for name, digest in protected.items():
        need(current.get(name) == digest, 'Protected source image changed')
    unknown_pruned = 0
    for item in preserved:
        name = relative_path(item['path']); images({name: item['sha256']})
        need(type(item['size']) is int and 0 <= item['size'] <= 64*1024**3,
             'Invalid preserved pruning payload size')
        unknown_pruned += advance(current, {name: item['sha256']}, {name: None}, unknown_allowed=True)
    for name in missing:
        relative_path(name)
        need(name not in current or current[name] is None, 'Missing pruning path contradicts replay')
        current[name] = None
    operations.append({'kind': 'literal-pruning', 'declaredRemovedPaths': len(preserved)})
    domain = native['domainSubstitution']
    pre, post = images(domain['preimages']), images(domain['postimages'])
    need(len(pre) == 17073 and set(pre) == set(post) and all(pre[n] is not None and post[n] is not None for n in pre) and
         type(domain['modifiedCount']) is int and domain['modifiedCount'] == 17009 == sum(pre[n] != post[n] for n in pre),
         'Domain substitution coverage/change count differs')
    absent = [relative_path(item['path']) for item in domain['absent']]
    need(len(absent) == len(set(absent)) == 855 and not set(absent) & set(pre), 'Domain absent coverage differs')
    for name in absent:
        need(name not in current or current[name] is None, 'Domain missing path contradicts replay')
        current[name] = None
    unknown_domain = advance(current, pre, post, unknown_allowed=True)
    operations.append({'kind': 'domain-substitution', 'observedPaths': len(pre), 'changedPaths': 17009})
    generated = native['generated']
    need(set(images(generated['outputs'], 5)) == GENERATED and len(generated['commands']) == 4,
         'Generated source output coverage differs')
    current.update(generated['outputs'])
    operations.append({'kind': 'generated-version-inputs', 'paths': sorted(GENERATED)})
    for index in range(1, 8): apply_patch(index, payload(CORRECTIONS[index][0]))
    types = payload('m156-pinned-build-types-restoration.json')
    need(types['version'] == '7.18.2' and types['archiveMembers'] == 46 and types['releaseReady'] is False and
         types['preserveDependencyValidator'] is True and types['preserveNativeTypeScript'] is True and
         types['noNpmInstall'] is True and len(types['files']) == 43 and len(types['metadata']) == 2,
         'Build types restoration contract differs')
    typed_names = set()
    for item in types['files']:
        name = relative_path(item['path'])
        need(name.startswith('third_party/node/node_modules/undici-types/') and name.endswith('.d.ts') and
             name not in typed_names and item['preimageSHA256'] is None and
             (name not in current or current[name] is None), 'Restored types path/preimage differs')
        images({name: item['postimageSHA256']}); typed_names.add(name); current[name] = item['postimageSHA256']
    for name, digest in images(types['metadata'], 2).items():
        need(name in {'third_party/node/node_modules/undici-types/LICENSE',
                      'third_party/node/node_modules/undici-types/package.json'} and
             (name not in current or current[name] == digest), 'Unchanged types metadata differs')
        current[name] = digest
    operations.append({'kind': 'exact-locked-build-types-restoration', 'addedDeclarationFiles': 43})
    apply_patch(8, payload(CORRECTIONS[8][0]))
    return {'schemaVersion': 1, 'status': 'subsequent-correction-image-order-verified-only',
            'orderedInputCount': 216, 'precedingSourceChangingPatchCount': 212,
            'nativeSupersessionCount': 4, 'subsequentPatchCount': 9, 'operations': operations,
            'requiredFinalSourceImages': current, 'requiredFinalSourceImagesSHA256': canonical_digest(current),
            'unanchoredPruningImageCount': unknown_pruned, 'unanchoredDomainImageCount': unknown_domain,
            'pruningPayloadAndFinalAbsenceStillRequired': True, 'domainCacheAndRecipeBindingStillRequired': True,
            'generatedProducerBindingStillRequired': True, 'typesPackageAndPriorAbsenceBindingStillRequired': True,
            'allPristineOriginsStillRequired': True, 'wholeSourceBindingStillRequired': True,
            'independentPatchApplicationStillRequired': True, 'sourceExecution': False,
            'sourceSnapshotVerified': False, 'binaryBindingVerified': False,
            'runtimeQualified': False, 'releaseReady': False}
