"""Closed source overlays for additive runtime proofs; never release authority.

Callers supply source-owned manifest digests. JSON may describe data, but cannot
select Python code, expand the set of manifests or qualify a runtime.
"""
from __future__ import annotations

import re
from pathlib import Path

import chromium_15612_release_evidence as base

HEX = re.compile(r'[0-9a-f]{64}\Z')


def _path(value: object) -> str:
    base.need(isinstance(value, str) and 0 < len(value) <= 512
              and '\\' not in value and not value.startswith('/')
              and all(part not in ('', '.', '..') for part in value.split('/')),
              'Unsafe additive source path')
    return value


def _digest(value: object) -> str:
    base.need(isinstance(value, str) and HEX.fullmatch(value) is not None,
              'Invalid additive digest')
    return value


def load_inputs(project: Path, pins: dict[str, str]) -> dict[str, dict]:
    """Authenticate exact manifests/patches and their closed modified-file set.

    This only reads public project inputs. It neither applies a patch nor reads
    the Chromium tree. Its result is an expectation for a later FD observation.
    """
    base.need(isinstance(pins, dict) and 1 <= len(pins) <= 8, 'Closed overlay manifests required')
    expected: dict[str, dict] = {}
    first_name = next(iter(pins))
    for name, digest in pins.items():
        _path(name); _digest(digest)
        base.need(name.startswith('runtime/'), 'Overlay input must be in runtime')
        manifest_path = base.safe_relative_regular(project, name)
        # Authenticate and parse the same bounded FD read. Reopening after the
        # digest would permit a changed manifest to select different inputs.
        manifest_raw = base.checked_file(manifest_path.parent, manifest_path.name)
        base.need(base.digest(manifest_raw) == digest, 'Overlay manifest drift')
        manifest = base.strict_json(manifest_raw)
        base.need(isinstance(manifest, dict), 'Overlay manifest must be an object')
        base.need(type(manifest.get('schemaVersion')) is int and manifest['schemaVersion'] == 1,
                  'Overlay manifest schema differs')
        if 'parentManifest' in manifest:
            base.need(manifest['parentManifest'] == first_name
                      and manifest.get('parentManifestSHA256') == pins[first_name],
                      'Overlay adapter predecessor differs')
        patch_name = _path(manifest.get('patchFile'))
        base.need('/' not in patch_name, 'Patch must be adjacent to pinned manifest')
        patch_path = base.safe_relative_regular(manifest_path.parent, patch_name)
        patch_raw = base.checked_file(patch_path.parent, patch_path.name)
        base.need(base.digest(patch_raw) == _digest(manifest.get('patchSHA256')), 'Overlay patch drift')
        before, after = [], []
        for line in patch_raw.decode('utf-8', errors='strict').splitlines():
            if line.startswith('--- '):
                base.need(line.startswith('--- a/'), 'Only existing source modifications supported')
                before.append(_path(line[6:]))
            elif line.startswith('+++ '):
                base.need(line.startswith('+++ b/'), 'Only existing source modifications supported')
                after.append(_path(line[6:]))
        rows = manifest.get('files')
        base.need(isinstance(rows, list) and 1 <= len(rows) <= 64, 'Bounded overlay files required')
        names = []
        for row in rows:
            base.need(isinstance(row, dict) and set(row) == {'path', 'preimageSHA256', 'postimageSHA256'},
                      'Overlay file record differs')
            path = _path(row['path']); names.append(path)
            base.need(path not in expected, 'Duplicate overlay source path')
            pre, post = _digest(row['preimageSHA256']), _digest(row['postimageSHA256'])
            base.need(pre != post, 'Overlay must describe an actual source change')
            expected[path] = {'preimageSHA256': pre, 'postimageSHA256': post}
        base.need(before == after == names, 'Patch and manifest path sets differ')
    return expected


def _record(value: object, name: str, digest: str) -> None:
    base.need(isinstance(value, dict)
              and set(value) == {'kind', 'path', 'mode', 'sizeBytes', 'sha256'}
              and value['kind'] == 'file' and value['path'] == name
              and type(value['mode']) is int and value['mode'] == 0o644
              and type(value['sizeBytes']) is int and 0 < value['sizeBytes'] <= 4 * 1024 * 1024
              and value['sha256'] == digest, 'Additive FD source record differs')


def verify_projection(changes: list, expected: dict[str, dict], postimages: dict[str, str]) -> None:
    """Validate every expected before/after record; missing context never passes."""
    base.need(isinstance(expected, dict) and expected and set(postimages) == set(expected),
              'Additive build source coverage differs')
    base.need(isinstance(changes, list) and len(changes) == len(expected), 'Additive delta coverage differs')
    names = []
    for item in changes:
        base.need(isinstance(item, dict) and set(item) == {'path', 'before', 'after'},
                  'Additive delta fields differ')
        name = _path(item['path']); names.append(name)
        base.need(name in expected and names.count(name) == 1, 'Unexpected or duplicate source delta')
        spec = expected[name]
        _record(item['before'], name, spec['preimageSHA256'])
        _record(item['after'], name, spec['postimageSHA256'])
        base.need(postimages[name] == item['after']['sha256'], 'Delta/build source postimage differs')
    base.need(names == sorted(expected), 'Additive source delta must be complete and sorted')
