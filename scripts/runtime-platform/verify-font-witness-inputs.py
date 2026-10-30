#!/usr/bin/env python3
"""Verify prepared font-witness provenance offline, never browser behavior."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import struct

EXPECTED_TEXT = {
    'components/ungoogled/BUILD.gn',
    'components/ungoogled/font_qa_witness_mac.h',
    'components/ungoogled/font_qa_witness_mac.mm',
    'chrome/BUILD.gn', 'chrome/app/BUILD.gn', 'chrome/app/chrome_main_delegate.cc',
    'content/renderer/BUILD.gn', 'content/renderer/renderer_main.cc',
}
EXPECTED_ASSETS = {'owned-canary.ttf', 'owned-family-collision.ttf'}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(value):
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or str(path) != value:
        raise ValueError('non-canonical input path')
    return path


def tiny_sfnt(data):
    """Check only the original fixture container; this is not a font sanitizer."""
    if len(data) > 4096 or len(data) < 12 or data[:4] != b'\x00\x01\x00\x00':
        raise ValueError('unexpected fixture format or size')
    count = struct.unpack_from('>H', data, 4)[0]
    if not 1 <= count <= 32 or 12 + count * 16 > len(data):
        raise ValueError('invalid SFNT table count')
    tables = {}
    for i in range(count):
        tag, _checksum, offset, length = struct.unpack_from('>4sIII', data, 12 + i * 16)
        if tag in tables or offset < 12 + count * 16 or offset + length > len(data):
            raise ValueError('invalid SFNT table bounds')
        tables[tag] = data[offset:offset + length]
    if not {b'head', b'maxp', b'name', b'glyf', b'loca', b'hmtx', b'cmap'}.issubset(tables):
        raise ValueError('missing fixture tables')
    if len(tables[b'maxp']) < 6 or struct.unpack_from('>H', tables[b'maxp'], 4)[0] != 3:
        raise ValueError('expected exactly three original fixture glyphs')


def verify(directory, chromium_root=None):
    manifest = json.loads((directory / 'chromium-font-witness.json').read_text())
    if manifest['releaseReady'] is not False:
        raise ValueError('input contract cannot certify a release')
    for file_key, hash_key in [('parentManifest', 'parentManifestSHA256'), ('patchFile', 'patchSHA256')]:
        if sha256(directory / str(relative(manifest[file_key]))) != manifest[hash_key]:
            raise ValueError(file_key + ' hash mismatch')
    rows = manifest['files']
    if len(rows) != 8 or {x['path'] for x in rows} != EXPECTED_TEXT:
        raise ValueError('unexpected source inventory')
    for row in rows:
        path = relative(row['path'])
        if row['preimageSHA256'] is None:
            if sha256(directory / 'witness' / path.name) != row['postimageSHA256']:
                raise ValueError('prepared source hash mismatch')
        if chromium_root and sha256(chromium_root / str(path)) != row['postimageSHA256']:
            raise ValueError('applied source hash mismatch')
    assets = manifest['fixedAssets']
    if len(assets) != 2 or {Path(x['source']).name for x in assets} != EXPECTED_ASSETS:
        raise ValueError('unexpected fixture inventory')
    for asset in assets:
        path = directory / str(relative(asset['source']))
        if sha256(path) != asset['sha256'] or path.stat().st_size != asset['bytes']:
            raise ValueError('fixture hash or size mismatch')
        tiny_sfnt(path.read_bytes())
        if chromium_root and sha256(chromium_root / str(relative(asset['path']))) != asset['sha256']:
            raise ValueError('applied fixture hash mismatch')
    return {'status': 'source-inputs-verified', 'textFiles': 8, 'fixedFixtures': 2,
            'chromiumSourceChecked': chromium_root is not None,
            'compiled': False, 'actualBrowser': False, 'releaseQualified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path(__file__).resolve().parents[2] / 'runtime/font-policy-v1')
    parser.add_argument('--chromium-root', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.directory, args.chromium_root)))
    except (OSError, KeyError, ValueError, TypeError, struct.error):
        print(json.dumps({'status': 'FAIL', 'reason': 'invalid or drifted witness inputs', 'releaseQualified': False}))
        raise SystemExit(1)
