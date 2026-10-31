#!/usr/bin/env python3
"""Verify the exact private V446 marker experiment; never a release capability.

No build provenance, host load, legal qualification or production authority is
inferred. This read-only checker only accepts frozen V447 or V508 QA bytes.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError('recipient verification helper unavailable')
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


LINEAGE = _load('v446_recipient_lineage', 'verify-recipient-runtime-lineage.py')
MARKER = _load('v446_recipient_marker', 'verify-recipient-webgpu-marker.py')

OFFER_SHA = '988f05c617ac7ddf460c37ac5de3537f2fb7b5bc60cf0dbfa634aed951f63faf'
IDENTITY_SHA = 'dfd1ec9f71d5d59da2c405f9c45579bf2a374b250e5ce1f5cad2399610d9182e'
BINDING_SHA = 'af956997d6c3b1f87514899dfc9a164e698cecae583942dfa0d1a83d0b07673d'
V508_BINDING_SHA = 'c4264d49e80670c09cf769f4031fae9740cbc1accfa5d37372b78d270b0df39a'
V508_RECEIPT_SHA = 'd1008af51b2a19a0cbe7fa05ffeef68fae57986ce27485ba73cdabce179d8fce'
ASSETS_SHA = '4554bf51ecaed1db9021776be273b73cbebd3b97809f50bfc80b20f735559ed4'
GPU_PATH = 'WebGPU.framework/Versions/A/WebGPU'
ASSETS_PATH = 'WebKit.framework/Versions/A/Resources/Assets.car'
IDENTITY_PATH = 'evidence/V445-BASELINE-RUNTIME-IDENTITY.json'
TEAM = 'H6VGU2M6JD'


class CapabilityError(ValueError):
    pass


def _sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _owned_file(root: Path, relative: str) -> Path:
    if root.is_symlink() or not root.is_dir():
        raise CapabilityError('expected physical directory')
    base = root.resolve(strict=True)
    path = root / relative
    # No symlink in any component of these explicit evidence paths.
    for parent in (path, *path.parents):
        if parent == root:
            break
        if parent.is_symlink():
            raise CapabilityError('evidence path contains symlink')
    if not path.is_file() or not path.resolve(strict=True).is_relative_to(base):
        raise CapabilityError('evidence file unavailable')
    return path


def _read_pinned_json(path: Path, expected: str) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2_000_000 or _sha(path) != expected:
        raise CapabilityError('pinned evidence identity mismatch')
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, UnicodeError, ValueError) as error:
        raise CapabilityError('pinned evidence is not JSON') from error
    if not isinstance(value, dict):
        raise CapabilityError('pinned evidence schema invalid')
    return value


def _verify_v508_overlays(offer: Path, manifest: dict, modified: Path, signed: Path) -> None:
    """Verify all 55 runtime replacements against components in the pinned offer."""
    components = manifest.get('sourceOfferComponents')
    if (not isinstance(components, list) or manifest.get('sourceOfferComponentCount') != len(components)):
        raise CapabilityError('overlay component inventory invalid')
    indexed = {}
    for row in components:
        if not isinstance(row, dict) or not isinstance(row.get('path'), str) or row['path'] in indexed:
            raise CapabilityError('overlay component inventory invalid')
        indexed[row['path']] = row
    attrs = sorted(path for path in indexed if path.startswith('overlays/')
                   and path.count('/') == 2 and path.endswith('/ATTRIBUTION.json'))
    if len(attrs) != 8:
        raise CapabilityError('overlay attribution inventory invalid')
    seen = set()
    for rel in attrs:
        component = indexed[rel]
        path = _owned_file(offer, rel)
        if (component.get('includedInOfferFolder') is not True or type(component.get('bytes')) is not int
                or component['bytes'] != path.stat().st_size or component.get('sha256') != _sha(path)):
            raise CapabilityError('overlay attribution component mismatch')
        try:
            attribution = json.loads(path.read_text(encoding='utf-8'))
            assets = attribution['assets']
        except (OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
            raise CapabilityError('overlay attribution invalid') from error
        if not isinstance(assets, list):
            raise CapabilityError('overlay attribution invalid')
        name = rel.split('/')[1]
        for row in assets:
            if not isinstance(row, dict):
                raise CapabilityError('overlay asset invalid')
            if row.get('replacesRuntimeSHA256') is None:
                continue
            source = row.get('path')
            if (not isinstance(source, str) or not source or '\\' in source or Path(source).is_absolute()
                    or '..' in Path(source).parts):
                raise CapabilityError('overlay asset path invalid')
            component_path = f'overlays/{name}/{source}'
            source_component = indexed.get(component_path)
            asset = _owned_file(offer, component_path)
            if (not isinstance(source_component, dict) or source_component.get('includedInOfferFolder') is not True
                    or type(row.get('bytes')) is not int or source_component.get('bytes') != row['bytes']
                    or asset.stat().st_size != row['bytes'] or source_component.get('sha256') != row.get('sha256')
                    or _sha(asset) != row.get('sha256')):
                raise CapabilityError('overlay asset component mismatch')
            path = Path(source)
            if source.startswith('Source/WebCore/Modules/modern-media-controls/images/macOS/'):
                target = Path('WebCore.framework/Versions/A/Resources/modern-media-controls/images') / path.name
            elif source.startswith('Source/WebCore/Resources/'):
                target = Path('WebCore.framework/Versions/A/Resources') / path.name
            else:
                raise CapabilityError('overlay asset target invalid')
            rel_target = target.as_posix()
            if rel_target in seen:
                raise CapabilityError('overlay target duplicate')
            seen.add(rel_target)
            for root in (modified, signed):
                if _sha(_owned_file(root, rel_target)) != row['sha256']:
                    raise CapabilityError('runtime overlay postimage mismatch')
    if len(seen) != 55:
        raise CapabilityError('runtime overlay count mismatch')


def _verify_v508_receipt(receipt_path: Path, binding_path: Path) -> None:
    receipt = _read_pinned_json(receipt_path, V508_RECEIPT_SHA)
    binding = _read_pinned_json(binding_path, V508_BINDING_SHA)
    if (receipt.get('schemaVersion') != 1 or receipt.get('offerSHA256') != OFFER_SHA
            or receipt.get('bindingSHA256') != V508_BINDING_SHA or receipt.get('imageCount') != 16):
        raise CapabilityError('V508 receipt identity mismatch')
    rows = receipt.get('images')
    actual = binding.get('images')
    if not isinstance(rows, list) or not isinstance(actual, list) or len(rows) != 16 or len(actual) != 16:
        raise CapabilityError('V508 receipt image inventory invalid')
    keys = ('path', 'sourceInputSHA256', 'recipientSignedSHA256')
    if any(not isinstance(row, dict) for row in rows + actual):
        raise CapabilityError('V508 receipt image row invalid')
    try:
        expected = {row['path']: tuple(row[k] for k in keys) for row in rows}
        observed = {row['path']: tuple(row[k] for k in keys) for row in actual}
    except (KeyError, TypeError) as error:
        raise CapabilityError('V508 receipt image row invalid') from error
    if len(expected) != 16 or len(observed) != 16 or expected != observed:
        raise CapabilityError('V508 receipt image mismatch')


def verify(offer: Path, source: Path, baseline: Path, modified: Path,
           signed: Path, binding: Path, v508_receipt: Path | None = None) -> dict:
    manifest = _read_pinned_json(_owned_file(offer, 'manifest.json'), OFFER_SHA)
    expected_selection = {'path': IDENTITY_PATH, 'sha256': IDENTITY_SHA}
    if (manifest.get('currentWebKitV465BaselineRuntime') != expected_selection
            or manifest.get('currentWebKitV467StabilizedRuntime') is not None):
        raise CapabilityError('V465 baseline selection mismatch')
    identity_file = _owned_file(offer, IDENTITY_PATH)
    identity = _read_pinned_json(identity_file, IDENTITY_SHA)
    rows = identity.get('stageAndSignedImages')
    if not isinstance(rows, list) or len(rows) != 16:
        raise CapabilityError('baseline image inventory invalid')
    expected = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('path'), str) or row['path'] in expected:
            raise CapabilityError('baseline image row invalid')
        expected[row['path']] = row.get('buildStageSHA256')
    if GPU_PATH not in expected:
        raise CapabilityError('baseline WebGPU absent')
    baseline_hashes = LINEAGE.image_hashes(baseline)
    modified_hashes = LINEAGE.image_hashes(modified)
    if len(baseline_hashes) != 16 or baseline_hashes != expected or set(modified_hashes) != set(expected):
        raise CapabilityError('baseline or modified image inventory mismatch')
    if [p for p in sorted(expected) if baseline_hashes[p] != modified_hashes[p]] != [GPU_PATH]:
        raise CapabilityError('modified images differ outside WebGPU or marker image unchanged')
    marker_result = MARKER.verify(source, _owned_file(modified, GPU_PATH))
    if marker_result.get('status') != 'local-marker-replay-and-image-pass':
        raise CapabilityError('marker verification failed')
    if binding.is_symlink() or not binding.is_file() or binding.stat().st_size > 2_000_000:
        raise CapabilityError('QA binding identity mismatch')
    binding_sha = _sha(binding)
    if binding_sha not in (BINDING_SHA, V508_BINDING_SHA):
        raise CapabilityError('QA binding identity mismatch')
    variant = 'V447' if binding_sha == BINDING_SHA else 'V508'
    if variant == 'V508':
        if v508_receipt is None:
            raise CapabilityError('V508 pinned receipt required')
        _verify_v508_receipt(v508_receipt, binding)
        _verify_v508_overlays(offer, manifest, modified, signed)
    elif v508_receipt is not None:
        raise CapabilityError('V508 receipt cannot be used for V447')
    signed_result = LINEAGE.verify_lineage(modified, signed, binding, TEAM)
    if signed_result.get('imageCount') != 16 or signed_result.get('releaseQualified') is not False:
        raise CapabilityError('signed runtime verification failed')
    for root in (baseline, modified, signed):
        asset = _owned_file(root, ASSETS_PATH)
        if _sha(asset) != ASSETS_SHA:
            raise CapabilityError('asset catalog mismatch')
    return {'schemaVersion': 1, 'status': 'private-v446-evidence-pass',
            'offerManifestSHA256': OFFER_SHA, 'baselineIdentitySHA256': IDENTITY_SHA,
            'bindingSHA256': binding_sha, 'qaVariant': variant, 'imageCount': 16, 'changedImage': GPU_PATH,
            'assetsSHA256': ASSETS_SHA, 'team': TEAM, 'releaseQualified': False,
            'limitations': ['no source-to-image build causality', 'no complete legal or notice qualification',
                            'no browser-host packaging or load', 'no production authority']}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('offer', 'source', 'baseline', 'modified', 'signed', 'binding'):
        parser.add_argument('--' + option, type=Path, required=True)
    parser.add_argument('--v508-receipt', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.offer, args.source, args.baseline, args.modified,
                                args.signed, args.binding, args.v508_receipt), sort_keys=True))
        return 0
    except (CapabilityError, LINEAGE.LineageError, LINEAGE.RESIGN.ResignError,
            LINEAGE.RESIGN.PACKAGER.ContractError, ValueError, OSError,
            subprocess.SubprocessError) as error:
        print('Private V446 evidence refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
