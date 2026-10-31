#!/usr/bin/env python3
"""Bind selected GN/Ninja CIPD manifests to their installed M156 copies.

This verifier performs bounded reads only. It does not fetch packages, execute
tools, change build inputs, or attest a completed native build. Manifest hashes
are pinned through the independently authenticated acquisition receipt, not
through mutable CIPD tags or an unchecked `_current` symlink.
"""
from __future__ import annotations

import ast
import base64
import hashlib
import os
from pathlib import Path
from typing import Any

from chromium_15612_generated_cache import VERSION, COMMIT, TREE, need, relative_path, read_source_file
from chromium_15612_input_lineage import ACQUISITION, DEPS_SHA256, primary_documents
from chromium_15612_receipt_projection import strict_json
from chromium_15612_tool_packages import directory_anchor, verify_installed

DAWN_COMMIT = '0a2c7df818e285d6db0f085135139cda04cee8bb'
DAWN_DEPS_SHA256 = 'cf584a7a8cfe3534c60ea3c1c16ae732c6e1a8cb393579a3480f6ff36102580c'
GN_VERSION = 'git_revision:510ec7992c30f172205792f190e96111a896ba8f'
NINJA_VERSION = 'version:3@1.12.1.chromium.4'
SPECS = {
    'gn': {
        'slot': '0', 'root': 'buildtools/mac', 'package': 'gn/gn/mac-arm64',
        'instance': 'pt5SZX89AaBzsAqpHbUS-F066dKywK1GlJzaToIE9ioC',
        'manifest': '2fa99e65c8bc2de147d811aa1d6d0bcc49e7722f02ff1e15d95b72165dc88d29',
        'count': 2, 'key': 'src/buildtools/mac:gn/gn/mac-${arch}/',
        'requested': 'https://chrome-infra-packages.appspot.com/gn/gn/mac-${arch}@' + GN_VERSION,
        'executable': 'gn', 'frozenTool': 'buildtools/mac/gn',
    },
    'ninja': {
        'slot': '7', 'root': 'third_party/ninja', 'package': 'infra/3pp/tools/ninja/mac-arm64',
        'instance': 'xem0_6s7Lt77xBhJ_IHxFsjQR7JYkGvswGG-nsrwSv0C',
        'manifest': '437218a6088dc9efd483365ddb882fcf986cbcd9dce86a917210b890e33790ac',
        'count': 3, 'key': 'src/third_party/ninja:infra/3pp/tools/ninja/${platform}/',
        'requested': 'https://chrome-infra-packages.appspot.com/infra/3pp/tools/ninja/${platform}@' + NINJA_VERSION,
        'executable': 'ninja', 'frozenTool': 'third_party/ninja/ninja',
    },
    'dawn-ninja': {
        'slot': '6', 'root': 'third_party/dawn/third_party/ninja', 'package': 'infra/3pp/tools/ninja/mac-arm64',
        'instance': 'xem0_6s7Lt77xBhJ_IHxFsjQR7JYkGvswGG-nsrwSv0C',
        'manifest': '437218a6088dc9efd483365ddb882fcf986cbcd9dce86a917210b890e33790ac',
        'count': 3, 'key': 'src/third_party/dawn/third_party/ninja:infra/3pp/tools/ninja/${platform}/',
        'requested': 'https://chrome-infra-packages.appspot.com/infra/3pp/tools/ninja/${platform}@' + NINJA_VERSION,
        'executable': 'ninja', 'frozenTool': 'third_party/ninja/ninja',
    },
}


def dictionary(tree: ast.Module, name: str) -> dict[str, ast.AST]:
    assignments = [n for n in tree.body if isinstance(n, ast.Assign) and
                   any(isinstance(t, ast.Name) and t.id == name for t in n.targets)]
    need(len(assignments) == 1 and len(assignments[0].targets) == 1 and
         isinstance(assignments[0].value, ast.Dict), 'Exactly one literal DEPS dictionary required')
    result = {}
    for key, value in zip(assignments[0].value.keys, assignments[0].value.values, strict=True):
        need(isinstance(key, ast.Constant) and type(key.value) is str and key.value not in result,
             'Dynamic or duplicate DEPS dictionary key refused')
        result[key.value] = value
    return result


def selected_value(node: ast.AST, variables: dict[str, ast.AST], depth: int = 0) -> Any:
    need(depth <= 16, 'Selected DEPS expression exceeds bound')
    if isinstance(node, ast.Constant):
        need(type(node.value) is str, 'Selected DEPS value must be a string')
        return node.value
    if isinstance(node, ast.Call):
        need(isinstance(node.func, ast.Name) and node.func.id == 'Var' and not node.keywords and
             len(node.args) == 1 and isinstance(node.args[0], ast.Constant) and
             type(node.args[0].value) is str and node.args[0].value in variables,
             'Unknown executable DEPS expression refused')
        # Only a selected, literal variable is needed for these package origins.
        return selected_value(variables[node.args[0].value], {}, depth + 1)
    if isinstance(node, ast.BinOp):
        need(isinstance(node.op, ast.Add), 'Unsupported DEPS expression refused')
        left, right = selected_value(node.left, variables, depth + 1), selected_value(node.right, variables, depth + 1)
        need(isinstance(left, str) and isinstance(right, str), 'DEPS concatenation must contain strings')
        return left + right
    if isinstance(node, ast.List):
        need(len(node.elts) <= 4, 'Selected DEPS list exceeds bound')
        return [selected_value(n, variables, depth + 1) for n in node.elts]
    if isinstance(node, ast.Dict):
        result = {}
        need(len(node.keys) <= 8, 'Selected DEPS object exceeds bound')
        for k, v in zip(node.keys, node.values, strict=True):
            need(isinstance(k, ast.Constant) and type(k.value) is str and k.value not in result,
                 'Dynamic or duplicate selected DEPS key refused')
            result[k.value] = selected_value(v, variables, depth + 1)
        return result
    need(False, 'Executable DEPS expression refused')


def deps_origins(raw: bytes, *, dawn: bool = False) -> dict[str, dict[str, Any]]:
    need(len(raw) <= 512 * 1024, 'DEPS exceeds bound')
    tree = ast.parse(raw.decode('utf8'))
    variables, dependencies = dictionary(tree, 'vars'), dictionary(tree, 'deps')
    # The production caller authenticates exact official bytes first. This
    # additionally rejects simple mutation fixtures; it is not a DEPS executor.
    for node in tree.body:
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
            fn = node.value.func
            need(not (isinstance(fn, ast.Attribute) and isinstance(fn.value, ast.Name) and
                      fn.value.id in {'vars', 'deps'}), 'Later DEPS dictionary mutation refused')
    selected = [('dawn-ninja', 'third_party/ninja',
                 {'dep_type': 'cipd', 'packages': [{'package': 'infra/3pp/tools/ninja/${{platform}}',
                                                  'version': NINJA_VERSION}]})] if dawn else [
        ('gn', 'src/buildtools/mac', {'dep_type': 'cipd', 'condition': 'host_os == "mac"',
         'packages': [{'package': 'gn/gn/mac-${{arch}}', 'version': GN_VERSION}]}),
        ('ninja', 'src/third_party/ninja', {'dep_type': 'cipd', 'condition': 'non_git_source',
         'packages': [{'package': 'infra/3pp/tools/ninja/${{platform}}', 'version': NINJA_VERSION}]}),
    ]
    result = {}
    for kind, key, expected in selected:
        need(key in dependencies, 'Selected CIPD dependency missing')
        observed = selected_value(dependencies[key], variables)
        need(observed == expected, 'Selected CIPD DEPS origin differs')
        result[kind] = observed
    return result


def tagged_sha256(value: Any) -> str:
    """Decode CIPD's URL-safe digest plus algorithm byte; SHA256 only.

    Format checked against LUCI common/iid.go at d1893ff5c6159f61fcce9656ddb763f780ce0221.
    Independent implementation; no upstream helper code is imported/executed.
    """
    need(isinstance(value, str) and len(value) == 44 and
         all(c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_' for c in value),
         'Invalid CIPD tagged SHA256')
    raw = base64.b64decode(value, altchars=b'-_', validate=True)
    need(len(raw) == 33 and raw[-1] == 2 and base64.urlsafe_b64encode(raw).decode() == value,
         'Unsupported or noncanonical CIPD hash')
    return raw[:-1].hex()


def manifest_members(document: dict[str, Any], spec: dict[str, Any]) -> tuple[dict, dict]:
    fields = {'format_version', 'package_name', 'install_mode', 'actual_install_mode', 'files'}
    if spec['package'] == 'gn/gn/mac-arm64': fields.add('version_file')
    need(isinstance(document, dict) and set(document) == fields and document['format_version'] == '1.1' and
         document['package_name'] == spec['package'] and document['install_mode'] == 'copy' and
         document['actual_install_mode'] == 'copy' and isinstance(document['files'], list) and
         len(document['files']) == spec['count'], 'Pinned CIPD manifest schema mismatch')
    if 'version_file' in document:
        need(document['version_file'] == '.versions/gn.cipd_version', 'CIPD version file mismatch')
    members, payload = {}, {}
    for entry in document['files']:
        need(isinstance(entry, dict) and set(entry) in ({'name', 'size', 'hash'}, {'name', 'size', 'hash', 'executable'}),
             'Unknown CIPD file fields')
        name = relative_path(entry.get('name'))
        need(name not in members and type(entry['size']) is int and 0 <= entry['size'] <= 8 * 1024 * 1024 and
             ('executable' not in entry or entry['executable'] is True), 'Invalid CIPD file metadata')
        # These immutable installed copy roots are frozen as readonly555/444,
        # unlike the755/644 GCS extracted roots. No generic chmod is performed.
        members[name] = {'kind': 'file', 'size': entry['size'], 'mode': '0o555' if entry.get('executable') else '0o444'}
        payload[name] = tagged_sha256(entry['hash'])
        parent = name.rpartition('/')[0]
        while parent:
            previous = members.get(parent)
            need(previous is None or previous['kind'] == 'directory', 'CIPD directory/file collision')
            members[parent] = {'kind': 'directory', 'size': 0, 'mode': '0o755'}
            parent = parent.rpartition('/')[0]
    need(spec['executable'] in members and members[spec['executable']]['mode'] == '0o555', 'CIPD executable missing')
    return members, payload


def verify_cipd_tools(artifacts: Path, source: Path) -> dict[str, Any]:
    primary = primary_documents(artifacts / 'm156-source-public-preparation-attempt-4')
    acquisition = primary[ACQUISITION]['payload']; records = acquisition['records']
    freeze = primary['m156-prebuild-attempt-4-contract.json']['payload']
    raw = read_source_file(artifacts, 'm156-DEPS.official', 512 * 1024)
    need(hashlib.sha256(raw).hexdigest() == DEPS_SHA256, 'Official root DEPS changed')
    origins = deps_origins(raw)
    dawn = records.get('src/third_party/dawn/')
    need(dawn == {'kind': 'git', 'revision': DAWN_COMMIT,
                  'url': 'https://dawn.googlesource.com/dawn.git@' + DAWN_COMMIT}, 'Dawn acquisition differs')
    raw = read_source_file(artifacts, 'm156-dawn-DEPS.official', 128 * 1024)
    need(hashlib.sha256(raw).hexdigest() == DAWN_DEPS_SHA256 and
         read_source_file(source, 'third_party/dawn/DEPS', 128 * 1024) == raw, 'Official Dawn DEPS changed')
    origins.update(deps_origins(raw, dawn=True))
    results = []
    checkout = source.parent
    for kind, spec in SPECS.items():
        expected = {'kind': 'cipd', 'instanceID': spec['instance'], 'manifestSHA256': spec['manifest'],
                    'manifestFiles': spec['count'], 'package': spec['package'], 'requested': spec['requested']}
        need(records.get(spec['key']) == expected, 'CIPD acquisition tuple mismatch')
        prefix = '.cipd/pkgs/' + spec['slot']
        description = strict_json(read_source_file(checkout, prefix + '/description.json', 4096))
        need(description == {'subdir': 'src/' + spec['root'], 'package_name': spec['package']}, 'CIPD slot differs')
        # Inspect the link itself; read all bytes via the pinned instance name.
        # Do not resolve an arbitrary _current target or any other symlink.
        with directory_anchor(checkout, prefix) as fd:
            before = os.stat('_current', dir_fd=fd, follow_symlinks=False)
            import stat
            need(stat.S_ISLNK(before.st_mode) and os.readlink('_current', dir_fd=fd) == spec['instance'],
                 'CIPD current instance differs')
            raw = read_source_file(checkout, prefix + '/' + spec['instance'] + '/.cipdpkg/manifest.json', 16384)
            need(hashlib.sha256(raw).hexdigest() == spec['manifest'], 'Pinned CIPD manifest changed')
            document = strict_json(raw)
            members, payload = manifest_members(document, spec)
            # CIPD copy installation retains the manifest here, not a second
            # payload copy or ZIP. Verify actual installed bytes below against
            # each manifest digest; do not invent an archive observation.
            after = os.stat('_current', dir_fd=fd, follow_symlinks=False)
            need((before.st_dev, before.st_ino, before.st_mtime_ns, before.st_ctime_ns) ==
                 (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_ctime_ns), 'CIPD current link changed')
        verify_installed(source, members, payload, spec['root'])
        need(payload[spec['executable']] == freeze['nativeToolHashes'][spec['frozenTool']], 'Frozen tool bytes differ')
        if kind == 'gn':
            version = strict_json(read_source_file(source, spec['root'] + '/.versions/gn.cipd_version', 4096))
            need(version == {'package_name': spec['package'], 'instance_id': spec['instance']}, 'GN version identity differs')
        results.append({**expected, 'tool': kind, 'sourceRoot': spec['root'],
                        'payloadFiles': spec['count'], 'payloadSHA256': payload,
                        'DEPSSelectionVerified': origins[kind], 'installedCopyVerified': True,
                        'retainedPackageArchiveVerified': False})
    return {'schemaVersion': 1, 'status': 'selected-CIPD-tools-source-only', 'chromiumVersion': VERSION,
            'officialChromiumBase': {'commit': COMMIT, 'tree': TREE}, 'rootDEPS_SHA256': DEPS_SHA256,
            'dawnDEPS_SHA256': DAWN_DEPS_SHA256, 'packages': results,
            'nativeBuildInvokedByVerifier': False, 'sourceMutation': False, 'toolExecution': False,
            'completedBuildAndFinalSnapshotBindingStillRequired': True,
            'binaryBindingVerified': False, 'runtimeQualified': False, 'releaseReady': False}
