#!/usr/bin/env python3
"""Replay the bounded V446 recipient marker; no release or build attestation."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PATCH = Path(__file__).resolve().parents[1] / 'docs/evidence/recipient-webgpu-v446-marker.patch'
SOURCE_SHA = '936cc760fe539b6a85752c1d5ce613a3bde1d4dbda2a8041aae86f26cdae1ef5'
PATCH_SHA = 'feccee8d7452718b259e09a8e0e05fc6d1c0d5e725f8996708ef437adbca22cb'
MODIFIED_SHA = 'c05a49c896c5308b9eaca6e10113f081f58d759aafee5c8179701ba1a13b5b27'
IMAGE_SHA = 'fd292af52b1011541c6bed02c010cdada4c51d2f115ffc0ce334dd679ae4daac'
MARKER = b'NEANTIK_RECIPIENT_RELINK_V446_20261028'


def digest(path: Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def verify(source: Path, image: Path, patch: Path = PATCH) -> dict:
    for path in (source, image, patch):
        if path.is_symlink() or not path.is_file():
            raise ValueError('inputs must be physical files')
    if digest(source) != SOURCE_SHA or digest(patch) != PATCH_SHA:
        raise ValueError('source or patch hash mismatch')
    if digest(image) != IMAGE_SHA:
        raise ValueError('modified WebGPU image hash mismatch')
    with image.open('rb') as f:
        image_bytes = f.read()
    if MARKER not in image_bytes:
        raise ValueError('test marker not present in modified image')
    with tempfile.TemporaryDirectory(prefix='neantik-recipient-marker-') as tmp:
        target = Path(tmp) / 'Source/WebGPU/WebGPU/Adapter.mm'
        target.parent.mkdir(parents=True)
        shutil.copyfile(source, target)
        for options in (['--check'], []):
            subprocess.run(['git', 'apply', *options, str(patch.resolve())], cwd=tmp,
                           check=True, capture_output=True)
        if digest(target) != MODIFIED_SHA or MARKER not in target.read_bytes():
            raise ValueError('replayed modified source hash mismatch')
    return {'status': 'local-marker-replay-and-image-pass', 'sourceSHA256': SOURCE_SHA,
            'patchSHA256': PATCH_SHA, 'modifiedSourceSHA256': MODIFIED_SHA,
            'modifiedImageSHA256': IMAGE_SHA, 'releaseQualified': False,
            'limitations': ['does not prove source-to-image build causality',
                            'does not validate licenses or recipient host load',
                            'specific V446 local exercise only']}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', required=True, type=Path)
    p.add_argument('--image', required=True, type=Path)
    args = p.parse_args()
    try:
        print(json.dumps(verify(args.source, args.image), sort_keys=True))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as e:
        print('Recipient marker verification refused: ' + str(e), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
