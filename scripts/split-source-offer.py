#!/usr/bin/env python3
"""Split a verified source artifact into bounded, independently hashed files.

This tool neither approves the input for publication nor uploads anything.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

MAX_PART = 1_900_000_000  # strictly below GitHub Releases' 2 GiB per file
BUFFER = 1024 * 1024


def split(source: Path, destination: Path, part_size: int = MAX_PART) -> dict:
    if source.is_symlink() or not source.is_file():
        raise ValueError('source must be a regular non-symlink file')
    if not 0 < part_size <= MAX_PART:
        raise ValueError('part size is outside the allowed range')
    if destination.exists() or destination.is_symlink():
        raise ValueError('destination already exists')
    before = source.stat()
    destination.mkdir(mode=0o700, parents=False)
    whole = hashlib.sha256()
    parts = []
    total = 0
    with source.open('rb') as incoming:
        while True:
            first = incoming.read(min(BUFFER, part_size))
            if not first:
                break
            name = f'part-{len(parts) + 1:04d}'
            remaining = part_size
            digest = hashlib.sha256()
            count = 0
            with (destination / name).open('xb') as output:
                chunk = first
                while chunk:
                    output.write(chunk); digest.update(chunk); whole.update(chunk)
                    count += len(chunk); total += len(chunk); remaining -= len(chunk)
                    chunk = incoming.read(min(BUFFER, remaining)) if remaining else b''
            parts.append({'name': name, 'bytes': count, 'sha256': digest.hexdigest()})
    after = source.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) or total != before.st_size:
        raise ValueError('source changed during splitting')
    if not parts:
        raise ValueError('source is empty')
    result = {'schemaVersion': 1, 'totalBytes': total, 'sha256': whole.hexdigest(), 'parts': parts}
    (destination / 'manifest.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def verify(directory: Path) -> dict:
    manifest = json.loads((directory / 'manifest.json').read_text())
    parts = manifest.get('parts')
    if manifest.get('schemaVersion') != 1 or not isinstance(parts, list) or not parts:
        raise ValueError('invalid manifest')
    whole = hashlib.sha256(); total = 0
    for index, part in enumerate(parts, 1):
        name = f'part-{index:04d}'
        if not isinstance(part, dict) or part.get('name') != name:
            raise ValueError('invalid part order')
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('part missing or unsafe')
        count = 0; digest = hashlib.sha256()
        with path.open('rb') as source:
            while chunk := source.read(BUFFER):
                count += len(chunk); total += len(chunk); digest.update(chunk); whole.update(chunk)
        if count != part.get('bytes') or not 0 < count <= MAX_PART or digest.hexdigest() != part.get('sha256'):
            raise ValueError('part changed or invalid')
    if total != manifest.get('totalBytes') or whole.hexdigest() != manifest.get('sha256'):
        raise ValueError('whole artifact mismatch')
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    make = sub.add_parser('split'); make.add_argument('source', type=Path); make.add_argument('destination', type=Path)
    check = sub.add_parser('verify'); check.add_argument('directory', type=Path)
    args = parser.parse_args()
    try:
        result = split(args.source, args.destination) if args.command == 'split' else verify(args.directory)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        raise SystemExit(f'Source offer split refused: {error}')
    print(f"PASS: {len(result['parts'])} parts, {result['totalBytes']} bytes, SHA-256 {result['sha256']}")


if __name__ == '__main__':
    main()
