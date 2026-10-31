#!/usr/bin/env python3
"""Export qualified notary outputs to independent immutable upload files.

The notary transaction retains hardlinks as its recovery evidence. Distribution
inputs must have a separate inode: hosted-download snapshotting deliberately
rejects hardlinks. This step copies bytes, never re-signs or re-packages them,
and never changes or removes the original transaction outputs.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat

MAXIMUM_BYTES = 16 * 1024 * 1024 * 1024


def signature(s):
    return (s.st_dev, s.st_ino, s.st_size, s.st_nlink, s.st_mtime_ns, s.st_ctime_ns)


def copy_verified(source: Path, target: Path, expected_hash: str | None = None, maximum_bytes: int = MAXIMUM_BYTES):
    descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
            or before.st_nlink not in (1, 2) or before.st_mode & 0o022
            or not 0 < before.st_size <= maximum_bytes):
            raise ValueError('unsafe distribution source')
        output = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            digest = hashlib.sha256()
            count = 0
            while chunk := os.read(descriptor, 1024 * 1024):
                count += len(chunk)
                if count > maximum_bytes:
                    raise ValueError('distribution source exceeds bound')
                digest.update(chunk)
                remaining = memoryview(chunk)
                while remaining:
                    written = os.write(output, remaining)
                    if written <= 0:
                        raise OSError('short distribution write')
                    remaining = remaining[written:]
            after = os.fstat(descriptor)
            named = os.stat(source, follow_symlinks=False)
            actual_hash = digest.hexdigest()
            if signature(before) != signature(after) or signature(after) != signature(named):
                raise ValueError('distribution source changed')
            if count != before.st_size or (expected_hash and actual_hash != expected_hash):
                raise ValueError('distribution checksum mismatch')
            os.fchmod(output, 0o400)
            os.fsync(output)
            copied = os.fstat(output)
            if copied.st_nlink != 1 or (copied.st_dev, copied.st_ino) == (before.st_dev, before.st_ino):
                raise ValueError('distribution output is not independent')
            return {'name': target.name, 'sha256': actual_hash, 'bytes': count}
        finally:
            os.close(output)
    finally:
        os.close(descriptor)


def export_distribution(source_dir: Path, destination: Path, version: str):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('invalid release version')
    # An exclusive private directory makes partial exports reviewable and
    # prevents a retry from replacing anything already prepared for upload.
    os.mkdir(destination, 0o700)
    files = []
    for extension in ('zip', 'dmg'):
        name = f'NeAntik-{version}-arm64-notarized.{extension}'
        sidecar = source_dir / (name + '.sha256')
        sidecar_result = copy_verified(sidecar, destination / sidecar.name, maximum_bytes=4096)
        value = (destination / sidecar.name).read_text(encoding='utf-8')
        match = re.fullmatch(r'([a-f0-9]{64})  ' + re.escape(name) + r'\n', value)
        if not match:
            raise ValueError('invalid checksum sidecar')
        files.append(copy_verified(source_dir / name, destination / name, match[1]))
        files.append(sidecar_result)
    # Re-open each output by name before attesting the complete set. A swapped
    # output cannot inherit the hash computed from the source descriptor.
    for item in files:
        fd = os.open(destination / item['name'], os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(fd)
            digest = hashlib.sha256()
            while chunk := os.read(fd, 1024 * 1024): digest.update(chunk)
            after = os.fstat(fd)
            named = os.stat(destination / item['name'], follow_symlinks=False)
            if (signature(before) != signature(after) or signature(after) != signature(named)
                or before.st_nlink != 1 or not stat.S_ISREG(before.st_mode)
                or before.st_uid != os.geteuid() or before.st_mode & 0o777 != 0o400
                or before.st_size != item['bytes'] or digest.hexdigest() != item['sha256']):
                raise ValueError('distribution output changed before receipt')
        finally: os.close(fd)
    receipt = {'schemaVersion': 1, 'version': version, 'files': files,
               'attestation': 'byte copy only; signing, notarization and hosted verification remain mandatory'}
    descriptor = os.open(destination / 'distribution.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    try:
        data = (json.dumps(receipt, indent=2) + '\n').encode()
        with os.fdopen(descriptor, 'wb', closefd=False) as handle:
            handle.write(data); handle.flush(); os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(directory)
    finally: os.close(directory)
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    print(json.dumps(export_distribution(args.source_dir, args.destination, args.version), indent=2))
