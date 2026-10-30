#!/usr/bin/env python3
"""Stage eight explicit common evidence inputs; never qualify a runtime.

Sources are keyed by their destination, so one baseline can populate both
historical and publication slots. Authenticate and retain every input before
creating an output directory. Subsequent runtime/release verification is still
required; this utility does not cache or replace it.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat


DESTINATIONS = {
    'lock': ('fingerprint-chromium.lock.json', 0o644),
    'provenance': ('source-provenance.json', 0o644),
    'args': ('args.gn', 0o644),
    'verification': ('runtime-verification.json', 0o600),
    'historicalBaseline': ('security-baseline.json', 0o644),
    'publicationBaseline': ('release-security-baseline.json', 0o600),
    'patchSeries': ('neantik-patch-series.json', 0o644),
    'deviceTuples': ('apple-device-tuples.json', 0o644),
}
MAX_INPUT_BYTES = 4 * 1024 * 1024


@dataclass(frozen=True)
class PreparedInput:
    destination: str
    mode: int
    sha256: str
    data: bytes


def _directory(path: Path) -> int:
    """Walk absolute components with no symlink following, including parents."""
    if not path.is_absolute() or any(p in ('.', '..') for p in path.parts):
        raise ValueError('Absolute canonical directory required')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read(path: Path) -> bytes:
    parent = _directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or not 0 < before.st_size <= MAX_INPUT_BYTES:
            raise ValueError('Evidence input must be an owned bounded regular file')
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, min(65536, MAX_INPUT_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_INPUT_BYTES:
                raise ValueError('Evidence input grew beyond limit')
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(before) != identity(after) or total != before.st_size:
            raise ValueError('Evidence input changed during read')
        return b''.join(chunks)
    finally:
        os.close(fd)


def prepare(plan: dict) -> tuple[PreparedInput, ...]:
    """Reject missing/extra roles, duplicate destinations and bad hashes first."""
    if not isinstance(plan, dict) or set(plan) != {'schemaVersion', 'inputs'} or type(plan['schemaVersion']) is not int or plan['schemaVersion'] != 1:
        raise ValueError('Evidence plan schema differs')
    rows = plan['inputs']
    if not isinstance(rows, list) or len(rows) != len(DESTINATIONS):
        raise ValueError('All eight named evidence inputs are required')
    seen, specs = set(), []
    for row in rows:
        if not isinstance(row, dict) or set(row) != {'role', 'source', 'sha256'}:
            raise ValueError('Evidence input fields differ')
        role = row['role']
        if not isinstance(role, str) or role not in DESTINATIONS or role in seen:
            raise ValueError('Unexpected or repeated evidence role')
        if not isinstance(row['source'], str) or not row['source'] or '\x00' in row['source'] or '..' in row['source'].split('/'):
            raise ValueError('Invalid evidence source path')
        digest = row['sha256']
        if not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None:
            raise ValueError('Invalid expected evidence hash')
        seen.add(role)
        specs.append((DESTINATIONS[role], Path(row['source']), digest))
    result = []
    for (destination, mode), path, digest in specs:
        raw = _read(path)
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('Evidence input hash mismatch: ' + destination)
        result.append(PreparedInput(destination, mode, digest, raw))
    return tuple(sorted(result, key=lambda item: item.destination))


def stage(inputs: tuple[PreparedInput, ...], destination: Path) -> None:
    """Write retained authenticated bytes to a new owned directory only.

    On I/O failure leave the incomplete new directory for diagnosis. Never
    overwrite, resume, sign, delete an old tree or claim atomic publication.
    """
    expected = set(DESTINATIONS.values())
    actual = {(item.destination, item.mode) for item in inputs}
    if len(inputs) != len(expected) or actual != expected:
        raise ValueError('Prepared evidence coverage differs')
    for item in inputs:
        if not isinstance(item.data, bytes) or hashlib.sha256(item.data).hexdigest() != item.sha256:
            raise ValueError('Prepared evidence bytes differ')
    parent = _directory(destination.parent)
    fd = None
    try:
        if destination.name in ('', '.', '..'):
            raise ValueError('New evidence directory required')
        os.mkdir(destination.name, 0o700, dir_fd=parent)
        fd = os.open(destination.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        root_stat = os.fstat(fd)
        for item in inputs:
            child = os.open(item.destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            with os.fdopen(child, 'wb') as stream:
                stream.write(item.data)
                os.fchmod(stream.fileno(), item.mode)
        final = os.stat(destination.name, dir_fd=parent, follow_symlinks=False)
        if (final.st_dev, final.st_ino) != (root_stat.st_dev, root_stat.st_ino):
            raise ValueError('Evidence destination changed during staging')
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def _object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError('Duplicate JSON field')
        result[name] = value
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', required=True, type=Path)
    parser.add_argument('--output-directory', type=Path, help='Absent: read-only preflight; present: must not exist')
    args = parser.parse_args()
    try:
        inputs = prepare(json.loads(_read(args.plan), object_pairs_hook=_object))
        if args.output_directory is not None:
            stage(inputs, args.output_directory)
        print(json.dumps({'schemaVersion': 1, 'status': 'staged' if args.output_directory else 'preflight-only',
                          'files': [{'destination': p.destination, 'sha256': p.sha256, 'sizeBytes': len(p.data), 'mode': p.mode} for p in inputs],
                          'releaseQualified': False}))
        return 0
    except (OSError, ValueError, TypeError):
        # Source paths and raw payloads are private; never echo them on failure.
        parser.exit(1, 'Common evidence preparation refused; check schema, explicit inputs, hashes and owned canonical paths.\n')


if __name__ == '__main__':
    raise SystemExit(main())
