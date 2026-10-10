"""Read only explicitly mapped native COPY hardlinks without changing old gates.

This is for trusted build inputs, never profile data or archive extraction.
Every alias must be an owned, stable, same-inode leaf under the exact output
directory; source plus named aliases must account for the full link count.
The caller independently authenticates the map and these helper buffers.
"""
from pathlib import Path
import hashlib
import os
import stat
import types
import chromium_15612_generated_cache as base
from chromium_15612_live_source import anchored_root, identity, anchor_node

OUTPUT_PREFIX = 'out/NeAntikM156Qualified20261009/'


def read_known_copy_source(root, name, maximum, record):
    base.need(name == record['path'] and not name.startswith('out/') and
              type(record['links']) is int and 2 <= record['links'] <= 8,
              'Explicit native COPY source required')
    aliases = record['outputAliases']
    base.need(isinstance(aliases, list) and len(aliases) == record['links']-1 and
              aliases == sorted(set(aliases)) and
              all(base.relative_path(n).startswith(OUTPUT_PREFIX) for n in aliases),
              'All native COPY aliases must be accounted inside exact output')
    handles, chain_anchors = [], []
    try:
        with anchored_root(root) as root_fd:
            def open_leaf(relative):
                parts = base.relative_path(relative).split('/')
                directory = os.dup(root_fd)
                handles.append(directory)
                for part in parts[:-1]:
                    before = os.stat(part, dir_fd=directory, follow_symlinks=False)
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    handles.append(child)
                    base.need(stat.S_ISDIR(before.st_mode) and before.st_uid == os.getuid() and
                              anchor_node(before) == anchor_node(os.fstat(child)),
                              'Native COPY ancestor changed during open')
                    chain_anchors.append((directory, part, child, anchor_node(before)))
                    directory = child
                leaf = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                handles.append(leaf)
                info = os.fstat(leaf)
                base.need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
                          info.st_dev == record['device'] and info.st_ino == record['inode'] and
                          info.st_nlink == record['links'] and info.st_size == record['sizeBytes'] and
                          stat.S_IMODE(info.st_mode) == record['mode'] and 0 <= info.st_size <= maximum,
                          'Native COPY identity/type/ownership/size changed')
                base.need(identity(info) == identity(os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)),
                          'Native COPY name changed during open')
                return directory, parts[-1], leaf, info
            source = open_leaf(name)
            opened = [source] + [open_leaf(alias) for alias in aliases]
            raw = bytearray()
            while len(raw) <= source[3].st_size:
                block = os.read(source[2], min(65536, source[3].st_size+1-len(raw)))
                if not block: break
                raw.extend(block)
            base.need(len(raw) == source[3].st_size and hashlib.sha256(raw).hexdigest() == record['sha256'],
                      'Native COPY source bytes differ')
            for parent, leaf, descriptor, before in opened:
                base.need(identity(before) == identity(os.fstat(descriptor)) ==
                          identity(os.stat(leaf, dir_fd=parent, follow_symlinks=False)),
                          'Native COPY changed during read')
            for parent, name, child, expected in chain_anchors:
                base.need(anchor_node(os.fstat(child)) == expected ==
                          anchor_node(os.stat(name, dir_fd=parent, follow_symlinks=False)),
                          'Native COPY ancestor replaced during read')
            return bytes(raw), source[3]
    finally:
        for descriptor in reversed(handles): os.close(descriptor)


def verify314_with_known_copy(root: Path, cache_record, python: Path, python_sha256: str, mapping):
    """Use the unchanged reviewed verifier with one closed, explicit reader.

    No base module globals are changed. All its cache, marshal, interpreter,
    filename and exact code-object comparison checks still execute unchanged.
    """
    def read_record(directory, name, maximum):
        base.need(directory == root, 'Native COPY source root differs')
        if name in mapping:
            return read_known_copy_source(root, name, maximum, mapping[name])
        return base.read_source_record(directory, name, maximum)
    namespace = {**base.verify_cache.__globals__, 'read_source_record': read_record}
    verifier = types.FunctionType(base.verify_cache.__code__, namespace)
    verifier(root, cache_record, python, python_sha256=python_sha256)
