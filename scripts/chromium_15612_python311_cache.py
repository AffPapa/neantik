#!/usr/bin/env python3
"""Verify the explicitly observed CPython3.11 caches from the settings target.

The older CPython3.14 verifier and its frozen receipts remain unchanged.
This does not import source or qualify native output. The caller authenticates
both helper buffers and the exact installed 3.11 interpreter independently.
The code-object wire fields match CPython v3.11.3 Python/marshal.c:525–549;
the shared structural preflight bounds allocation before native decoding.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path
import chromium_15612_generated_cache as base

CACHE311 = re.compile(r'(.+)/__pycache__/([^/]+)\.cpython-311\.pyc\Z')
PYTHON311_SHA256 = 'c220ae7b6c2b9da2a4e498c09cdbc64b03b43db96dbbf9f64d26bfbbd698e2bd'
PYTHON311 = Path('/Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11')
assert base.CACHE_CHECK_PROGRAM.count('need(sys.version_info[:2] == (3, 14))') == 1
PROGRAM311 = base.CACHE_CHECK_PROGRAM.replace(
    'need(sys.version_info[:2] == (3, 14))', 'need(sys.version_info[:3] == (3, 11, 3))')


def read_pinned_system_tool():
    """The existing system Python is root-owned, unlike owned source files."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    directories = [os.open('/', flags)]
    anchors = []
    descriptor = None
    identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_nlink,
                          s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    try:
        for part in PYTHON311.parts[1:-1]:
            parent = directories[-1]
            before = os.stat(part, dir_fd=parent, follow_symlinks=False)
            child = os.open(part, flags, dir_fd=parent)
            directories.append(child)
            base.need(stat.S_ISDIR(before.st_mode) and before.st_uid == 0 and
                      not before.st_mode & 0o002 and identity(before) == identity(os.fstat(child)),
                      'System interpreter ancestor differs')
            anchors.append((parent, part, child, identity(before)))
        descriptor = os.open(PYTHON311.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directories[-1])
        before = os.fstat(descriptor)
        base.need(stat.S_ISREG(before.st_mode) and before.st_uid == 0 and before.st_nlink == 1 and
                  not before.st_mode & 0o002 and 0 < before.st_size <= 128*1024*1024,
                  'System interpreter type/owner/size differs')
        raw = bytearray()
        while len(raw) <= before.st_size:
            part = os.read(descriptor, min(65536, before.st_size + 1 - len(raw)))
            if not part: break
            raw.extend(part)
        base.need(len(raw) == before.st_size and identity(before) == identity(os.fstat(descriptor)) ==
                  identity(os.stat(PYTHON311.name, dir_fd=directories[-1], follow_symlinks=False)),
                  'System interpreter changed during read')
        for parent, name, child, expected in anchors:
            base.need(identity(os.fstat(child)) == expected ==
                      identity(os.stat(name, dir_fd=parent, follow_symlinks=False)),
                      'System interpreter ancestor changed during read')
        return bytes(raw)
    finally:
        if descriptor is not None: os.close(descriptor)
        for directory in reversed(directories): os.close(directory)


def compare_observed_target_caches(before, after):
    """Permit new 311 caches only; every other delta retains the 314 contract."""
    old, new = base.inventory(before), base.inventory(after)
    records, names = [], set()
    for name in sorted(set(old) | set(new)):
        previous, current = old.get(name), new.get(name)
        if previous == current or not CACHE311.fullmatch(name):
            continue
        match = CACHE311.fullmatch(name)
        base.need(previous is None and current is not None and current['kind'] == 'file' and
                  current['mode'] == 0o644 and current['sizeBytes'] <= 4*1024*1024,
                  'Only newly observed bounded CPython3.11 caches are permitted')
        source = match[1] + '/' + match[2] + '.py'
        base.need(source in old and old[source]['kind'] == 'file' and old[source] == new.get(source),
                  'CPython3.11 cache source absent or changed')
        records.append({'cache': name, 'source': source, 'cacheSHA256': current['sha256'],
                        'sourceSHA256': old[source]['sha256'], 'cacheBytes': current['sizeBytes']})
        names.add(name)
    base.need(len(records) <= 1024, 'CPython3.11 cache limit exceeded')
    filtered = copy.deepcopy(after)
    filtered['entries'] = [item for item in filtered['entries'] if item['path'] not in names]
    filtered['sourceFileCount'] = len(filtered['entries'])
    return {'cpython311': records, 'cpython314': base.compare_inventories(before, filtered)}


def verify311(root: Path, record, python: Path = PYTHON311):
    base.need(set(record) == {'cache', 'source', 'cacheSHA256', 'sourceSHA256', 'cacheBytes'},
              'CPython3.11 record schema differs')
    match = CACHE311.fullmatch(base.relative_path(record['cache']))
    base.need(match is not None and record['source'] == match[1] + '/' + match[2] + '.py',
              'CPython3.11 source correspondence differs')
    for field in ('cacheSHA256', 'sourceSHA256'):
        base.need(isinstance(record[field], str) and base.HASH.fullmatch(record[field]),
                  'CPython3.11 digest invalid')
    base.need(type(record['cacheBytes']) is int and 16 < record['cacheBytes'] <= 4*1024*1024,
              'CPython3.11 cache length invalid')
    raw = base.read_source_file(root, record['cache'], 4*1024*1024)
    source, info = base.read_source_record(root, record['source'], 4*1024*1024)
    base.need(len(raw) == record['cacheBytes'] and hashlib.sha256(raw).hexdigest() == record['cacheSHA256'] and
              hashlib.sha256(source).hexdigest() == record['sourceSHA256'], 'CPython3.11 bytes differ')
    base.MarshalPreflight(raw[16:]).validate()
    # Exact tool, not a general alternative Python selector.
    base.need(python == PYTHON311, 'Only the observed pinned CPython3.11 tool is accepted')
    tool = read_pinned_system_tool()
    base.need(hashlib.sha256(tool).hexdigest() == PYTHON311_SHA256, 'CPython3.11 tool changed')
    item = {'cacheHex': raw.hex(), 'sourceHex': source.hex(),
            'sourceTimestamp': int(info.st_mtime) & 0xffffffff,
            'sourceFilename': str(root / record['source']), 'sourceRoot': str(root)}
    result = subprocess.run([str(python), '-I', '-S', '-B', '-c', PROGRAM311],
                            input=json.dumps(item), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=15, check=False)
    base.need(result.returncode == 0 and result.stdout.strip() == 'verified-source-derived-cache',
              'CPython3.11 derivation failed')
    base.need(read_pinned_system_tool() == tool,
              'CPython3.11 tool changed during verification')
