"""Closed security source inputs; never runtime or release qualification.

Callers independently pin the manifest and observed build/source receipts.
Projection checks below do not observe a live tree or prove ancestor membership.
The additive runtime verifier must also verify the full FD delta and binaries.
"""
from pathlib import Path, PurePosixPath
import re
import chromium_15612_release_evidence as base

DIRECTORY = 'runtime/security-backports-20261015'
CHROMIUM_COMMIT = '634b046faf2137b83af71c87baf362b533af9104'
V8_COMMIT = '4b33f15d4d172248a95629d6aa9917b20a79ad76'
V8_ISSUES = {'568831769', '569286602', '569659194'}
ISSUES = {'568719351', '567638392', '568937999', '569038297', '563194341'} | V8_ISSUES
PREEXISTING = {'501886301', '556272421'}


def need(condition, message):
    if not condition:
        raise ValueError('Security source delta refused: ' + message)


def relative(raw):
    need(isinstance(raw, str) and raw and '\\' not in raw and '\x00' not in raw,
         'unsafe source path')
    parts = PurePosixPath(raw).parts
    need(not raw.startswith('/') and raw == '/'.join(parts)
         and all(part not in ('', '.', '..', '.git') for part in raw.split('/')),
         'unsafe source path')
    return raw


def digest(raw):
    return isinstance(raw, str) and re.fullmatch(r'[0-9a-f]{64}', raw) is not None


def load_inputs(project: Path, manifest_sha256: str) -> dict:
    """Verify independently pinned patches, roots and the closed 35-file set."""
    need(digest(manifest_sha256), 'manifest pin required')
    directory = project / DIRECTORY
    manifest = base.bound(directory, 'manifest.json', manifest_sha256)
    need(type(manifest.get('schemaVersion')) is int and manifest['schemaVersion'] == 1
         and manifest.get('baseChromiumVersion') == base.VERSION
         and manifest.get('baseChromiumCommit') == CHROMIUM_COMMIT
         and manifest.get('baseV8Commit') == V8_COMMIT
         and manifest.get('securityBatch') == '2026-10-15', 'base identity mismatch')
    need(manifest.get('runtimeBuilt') is False and manifest.get('releaseQualified') is False
         and manifest.get('publicAlphaExceptionAllowed') is False,
         'patch manifest is not runtime qualification')
    need(manifest.get('baseFontSourceContractSHA256') == base.sha256_file(
        base.safe_relative_regular(project, 'runtime/chromium-15612-font-system-v1-source-contract.json')),
        'font ancestor contract mismatch')
    patches = manifest.get('orderedPatches')
    need(isinstance(patches, list) and len(patches) == 8, 'eight complete patches required')
    observed_issues, observed_paths, patch_names = set(), {}, set()
    for index, patch in enumerate(patches, 1):
        need(isinstance(patch, dict) and type(patch.get('order')) is int
             and patch['order'] == index, 'patch order mismatch')
        issue = patch.get('issue')
        need(isinstance(issue, str) and issue in ISSUES and issue not in observed_issues,
             'unknown or duplicate fix')
        observed_issues.add(issue)
        v8 = issue in V8_ISSUES
        repo, root = ('v8/v8', 'v8') if v8 else ('chromium/src', '.')
        commit = patch.get('commit')
        need(isinstance(commit, str) and re.fullmatch(r'[0-9a-f]{40}', commit)
             and patch.get('repository') == repo and patch.get('applyRoot') == root
             and type(patch.get('strip')) is int and patch['strip'] == 1
             and patch.get('upstreamReference') == f'https://chromium.googlesource.com/{repo}/+/{commit}',
             'patch upstream/root mismatch')
        name = relative(patch.get('path'))
        need(name.startswith(DIRECTORY + '/') and len(PurePosixPath(name).parts) == 3
             and name.endswith('.patch') and name not in patch_names, 'patch path mismatch')
        patch_names.add(name)
        need(digest(patch.get('sha256')) and base.sha256_file(
            base.safe_relative_regular(project, name)) == patch['sha256'], 'patch bytes changed')
        files = patch.get('files')
        before = patch.get('beforeFiles')
        need(isinstance(files, list) and files and isinstance(before, list), 'source files missing')
        before_map = {}
        for item in before:
            need(isinstance(item, dict) and set(item) == {'path', 'beforeSHA256'}, 'before fields differ')
            path = relative(item['path'])
            need(path not in before_map and digest(item['beforeSHA256']), 'invalid before-file pin')
            before_map[path] = item['beforeSHA256']
        expected_before = {}
        for item in files:
            need(isinstance(item, dict) and set(item) == {
                'path', 'change', 'beforeSHA256', 'upstreamPostimageGitBlob'}, 'source file fields differ')
            path = relative(item['path'])
            kind = item['change']
            need(kind in {'add', 'modify', 'delete'}, 'invalid source change')
            need((item['beforeSHA256'] is None) if kind == 'add' else digest(item['beforeSHA256']),
                 'before hash does not match change')
            git_blob = item['upstreamPostimageGitBlob']
            need(isinstance(git_blob, str) and re.fullmatch(r'[0-9a-f]{40}', git_blob), 'invalid upstream blob')
            full_path = path if root == '.' else 'v8/' + path
            need(full_path not in observed_paths, 'overlapping or duplicate source path')
            observed_paths[full_path] = {'change': kind, 'beforeSHA256': item['beforeSHA256']}
            if kind != 'add':
                expected_before[path] = item['beforeSHA256']
        need(before_map == expected_before, 'before-file set mismatch')
    need(observed_issues == ISSUES and len(observed_paths) == 35, 'closed source namespace differs')
    present = manifest.get('alreadyIncludedProductionFixes')
    need(isinstance(present, list) and len(present) == 2
         and {row.get('issue') for row in present if isinstance(row, dict)} == PREEXISTING,
         'preexisting fix evidence missing')
    need(manifest.get('licenseFiles') == ['CHROMIUM_LICENSE.txt', 'V8_LICENSE.txt'], 'license namespace differs')
    for name in manifest['licenseFiles']:
        raw = base.safe_relative_regular(directory, name).read_bytes()
        need(0 < len(raw) <= 16_384 and b'Redistribution and use in source and binary forms' in raw,
             'BSD license missing')
    return observed_paths


def record(value, path):
    need(isinstance(value, dict) and set(value) == {'kind', 'path', 'mode', 'sizeBytes', 'sha256'}
         and value['kind'] == 'file' and value['path'] == path
         and type(value['mode']) is int and value['mode'] == 0o644
         and type(value['sizeBytes']) is int and 0 < value['sizeBytes'] <= 4 * 1024 * 1024
         and digest(value['sha256']), 'invalid source record')


def verify_projection(changes: list, expected: dict, build_postimages: dict) -> None:
    """Compare metadata against independently bound ancestor/build records.

    A caller must derive these changes from the full source observation; the
    caller must not substitute this function for observing the source tree.
    """
    need(isinstance(changes, list) and len(changes) == len(expected) == 35
         and set(build_postimages) == set(expected), 'closed projection coverage differs')
    seen = set()
    for item in changes:
        need(isinstance(item, dict) and set(item) == {'path', 'before', 'after'}, 'delta fields differ')
        path = relative(item['path'])
        need(path in expected and path not in seen, 'unrelated or duplicate delta path')
        seen.add(path)
        kind = expected[path]['change']
        before, after = item['before'], item['after']
        if kind == 'add':
            need(before is None, 'added source unexpectedly existed')
        else:
            record(before, path)
            need(before['sha256'] == expected[path]['beforeSHA256'], 'source preimage gap')
        if kind == 'delete':
            need(after is None and build_postimages[path] is None, 'deleted source still present')
        else:
            record(after, path)
            need(digest(build_postimages[path]) and after['sha256'] == build_postimages[path],
                 'source postimage does not match build')
    need([item['path'] for item in changes] == sorted(expected), 'source delta is not canonical')
