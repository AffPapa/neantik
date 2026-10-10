#!/usr/bin/env python3
"""Independently observe every M156 source leaf after the native build exits.

The frozen snapshot producer is unchanged. This observer never follows source
symlinks, executes source, fetches, compiles, or qualifies a browser. Directory
descriptors stay anchored during reads. Full observations require exclusive
source custody; a sequential filesystem scan is not an atomic filesystem
snapshot. Empty directories and directory modes are not source records.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import selectors
import stat
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import chromium_15612_generated_cache as cache
import chromium_15612_postbuild as postbuild
import chromium_15612_receipt_projection as projection

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
MAX_DEPTH = 128
MAX_DIRECTORIES = 2_000_000
BLOCK = 1024 * 1024


def node(info: os.stat_result) -> tuple[int, ...]:
    return info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink


def identity(info: os.stat_result) -> tuple[int, ...]:
    return (*node(info), info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def anchor_node(info: os.stat_result) -> tuple[int, ...]:
    # APFS directory nlink can change when owned child names are published.
    # An ancestor anchor proves the directory inode/mode/owner, not its entries;
    # observe_tree separately checks entry lists and complete directory stats.
    return info.st_dev, info.st_ino, info.st_mode, info.st_uid


@contextmanager
def anchored_root(source: Path):
    """Hold all absolute ancestors; a replaced ancestor cannot hide a read."""
    cache.need(source.is_absolute() and len(source.parts) <= MAX_DEPTH and
               all(part not in {'', '.', '..'} for part in source.parts[1:]),
               'Absolute, bounded source root required')
    descriptors = [os.open('/', DIR_FLAGS)]
    anchors = []
    try:
        for part in source.parts[1:]:
            parent = descriptors[-1]
            before = os.stat(part, dir_fd=parent, follow_symlinks=False)
            descriptor = os.open(part, DIR_FLAGS, dir_fd=parent)
            descriptors.append(descriptor)
            cache.need(anchor_node(before) == anchor_node(os.fstat(descriptor)) and
                       stat.S_ISDIR(before.st_mode), 'Source ancestor changed during open')
            anchors.append((parent, part, descriptor, anchor_node(before)))
        cache.need(os.fstat(descriptors[-1]).st_uid == os.getuid(),
                   'Source root ownership differs')
        yield descriptors[-1]
        for parent, part, descriptor, expected in reversed(anchors):
            cache.need(anchor_node(os.fstat(descriptor)) == expected ==
                       anchor_node(os.stat(part, dir_fd=parent, follow_symlinks=False)),
                       'Source ancestor replaced during observation')
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def file_record(parent: int, leaf: str, name: str, before: os.stat_result,
                expected: dict[str, Any]) -> dict[str, Any]:
    cache.need(expected['kind'] == 'file' and stat.S_ISREG(before.st_mode) and
               before.st_uid == os.getuid() and before.st_nlink == 1 and
               before.st_size == expected['sizeBytes'] and
               stat.S_IMODE(before.st_mode) == expected['mode'],
               'Source file type, size, mode or ownership differs')
    descriptor = os.open(leaf, FILE_FLAGS, dir_fd=parent)
    try:
        cache.need(identity(os.fstat(descriptor)) == identity(before),
                   'Source leaf replaced before read')
        digest = hashlib.sha256()
        count = 0
        while count <= before.st_size:
            block = os.read(descriptor, min(BLOCK, before.st_size + 1 - count))
            if not block:
                break
            count += len(block)
            digest.update(block)
        cache.need(count == before.st_size and identity(before) ==
                   identity(os.fstat(descriptor)) ==
                   identity(os.stat(leaf, dir_fd=parent, follow_symlinks=False)),
                   'Source leaf changed during read')
        result = {'kind': 'file', 'path': name, 'mode': stat.S_IMODE(before.st_mode),
                  'sizeBytes': count, 'sha256': digest.hexdigest()}
        cache.need(result == expected, 'Observed source bytes differ')
        return result
    finally:
        os.close(descriptor)


def symlink_record(parent: int, leaf: str, name: str, before: os.stat_result,
                   expected: dict[str, Any]) -> dict[str, Any]:
    cache.need(expected['kind'] == 'symlink' and stat.S_ISLNK(before.st_mode) and
               before.st_uid == os.getuid() and expected['targetLength'] <= 4096,
               'Unsafe source symlink record')
    target = os.fsencode(os.readlink(leaf, dir_fd=parent))
    cache.need(identity(before) ==
               identity(os.stat(leaf, dir_fd=parent, follow_symlinks=False)),
               'Source symlink changed during observation')
    result = {'kind': 'symlink', 'path': name, 'mode': stat.S_IMODE(before.st_mode),
              'targetLength': len(target), 'targetSHA256': hashlib.sha256(target).hexdigest()}
    cache.need(result == expected, 'Observed source symlink differs')
    return result


def observe_tree(source: Path, full: dict[str, Any]) -> dict[str, Any]:
    """Compare every expected leaf and refuse extra leaves before content reads.

    Frozen producer excludes normal .git nodes and the real root out directory.
    Its exclusion treatment for symlinks named .git/out follows their target to
    classify them. Such ambiguous exclusions are refused here, not followed.
    Ordinary symlink target bytes (including external/dangling targets) are
    recorded without resolving them. No contents of those targets are read.
    """
    expected = cache.inventory(full)
    seen: set[str] = set()
    directories = 0

    def walk(descriptor: int, prefix: str, depth: int) -> None:
        nonlocal directories
        directories += 1
        cache.need(depth <= MAX_DEPTH and directories <= MAX_DIRECTORIES,
                   'Source traversal exceeds bounded directory budget')
        before = os.fstat(descriptor)
        cache.need(stat.S_ISDIR(before.st_mode) and before.st_uid == os.getuid(),
                   'Source directory ownership differs')
        names = sorted(os.listdir(descriptor))
        cache.need(len(names) <= 2_000_000, 'Source directory entry budget exceeded')
        for leaf in names:
            name = cache.relative_path(prefix + leaf)
            info = os.stat(leaf, dir_fd=descriptor, follow_symlinks=False)
            excluded = leaf == '.git' or (prefix == '' and leaf == 'out' and
                                         stat.S_ISDIR(info.st_mode))
            if leaf == '.git' or (prefix == '' and leaf == 'out'):
                cache.need(not stat.S_ISLNK(info.st_mode),
                           'Ambiguous excluded symlink refused')
            if excluded:
                cache.need(name not in expected, 'Inventory claims excluded source node')
                continue
            if stat.S_ISDIR(info.st_mode):
                cache.need(name not in expected, 'Inventory leaf changed to directory')
                child = os.open(leaf, DIR_FLAGS, dir_fd=descriptor)
                try:
                    cache.need(identity(info) == identity(os.fstat(child)),
                               'Source directory replaced before traversal')
                    walk(child, name + '/', depth + 1)
                    cache.need(identity(info) == identity(os.fstat(child)) ==
                               identity(os.stat(leaf, dir_fd=descriptor, follow_symlinks=False)),
                               'Source directory replaced during traversal')
                finally:
                    os.close(child)
            else:
                cache.need(name in expected and name not in seen,
                           'Extra or duplicate source leaf')
                if stat.S_ISREG(info.st_mode):
                    file_record(descriptor, leaf, name, info, expected[name])
                elif stat.S_ISLNK(info.st_mode):
                    symlink_record(descriptor, leaf, name, info, expected[name])
                else:
                    cache.need(False, 'Special source node refused')
                seen.add(name)
        cache.need(identity(before) == identity(os.fstat(descriptor)) and
                   names == sorted(os.listdir(descriptor)),
                   'Source directory changed during traversal')

    with anchored_root(source) as root:
        walk(root, '', 0)
    cache.need(seen == expected.keys(), 'Missing source leaf')
    return {'sourceFileCount': len(seen), 'observedDirectoryCount': directories,
            'fdSafeFullObservationVerified': True, 'exactCoverageVerified': True,
            'entriesSHA256': postbuild.canonical_digest(full['entries'])}


def git_output(source: Path, arguments: list[str], maximum: int) -> bytes:
    """Read-only Git plumbing with bounded stdout/stderr and no fsmonitor hook."""
    command = ['/usr/bin/git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
               '-C', str(source), *arguments]
    environment = {'PATH': '/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM': '1',
                   'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_OPTIONAL_LOCKS': '0'}
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=environment) as process:
        result = bytearray()
        error_bytes = 0
        deadline = time.monotonic() + 120
        selector = selectors.DefaultSelector()
        try:
            selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
            selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
            while selector.get_map():
                cache.need(time.monotonic() < deadline, 'Source Git observation timed out')
                for key, _ in selector.select(timeout=1):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                    elif key.data == 'stdout':
                        cache.need(len(result) + len(block) <= maximum,
                                   'Source Git output exceeds bound')
                        result.extend(block)
                    else:
                        error_bytes += len(block)
                        cache.need(error_bytes <= 65536, 'Source Git error output exceeds bound')
            cache.need(process.wait(timeout=max(0.1, deadline-time.monotonic())) == 0,
                       'Source Git observation failed')
            return bytes(result)
        except BaseException:
            process.kill()
            process.wait()
            raise
        finally:
            selector.close()


def git_identity(source: Path, full: dict[str, Any]) -> None:
    with anchored_root(source):
        commit = git_output(source, ['rev-parse', 'HEAD'], 128).decode().strip()
        tree = git_output(source, ['rev-parse', 'HEAD^{tree}'], 128).decode().strip()
        cache.need((commit, tree) == (cache.COMMIT, cache.TREE), 'Live Chromium Git base differs')
        deleted = sorted(os.fsdecode(name) for name in
                         git_output(source, ['ls-files', '--deleted', '-z'], 32*1024*1024).split(b'\0')
                         if name)
        cache.need(deleted == full['deletedPaths'], 'Live deleted paths differ')


def require_tools(hashes: dict[str, str]) -> None:
    directory = Path(__file__).absolute().parent
    modules = [sys.modules[__name__], cache, postbuild, projection]
    names = {Path(module.__file__).name for module in modules}
    cache.need(set(hashes) == names, 'Exact observer and dependency pins required')
    for module in modules:
        path = Path(module.__file__).absolute()
        cache.need(path.parent == directory and
                   hashlib.sha256(cache.read_source_file(directory, path.name, 1024*1024)).hexdigest()
                   == hashes[path.name], 'Observer source or loaded dependency differs')


def write_observation_document(artifacts: Path, name: str, value: dict[str, Any]) -> str:
    """Exclusive immutable JSON publication bound to the still-held write FD.

    Never delete a replaced temporary pathname. Publication and readback must
    refer to the inode we wrote, not merely a name with the expected suffix.
    On failure evidence may remain for diagnosis; no successful receipt is
    returned. Existing final evidence is never replaced.
    """
    import uuid
    cache.relative_path(name)
    cache.need('/' not in name, 'Flat owned evidence name required')
    temporary = name + '.new-' + uuid.uuid4().hex
    with anchored_root(artifacts) as directory:
        descriptor = os.open(temporary, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        original = os.fstat(descriptor)
        try:
            digest = hashlib.sha256()
            count = 0
            # Stream the million-record JSON without a second full byte copy.
            with os.fdopen(os.dup(descriptor), 'w', encoding='utf8', newline='\n') as stream:
                for text in json.JSONEncoder(indent=2, sort_keys=True).iterencode(value):
                    encoded = text.encode('utf8'); digest.update(encoded); count += len(encoded)
                    stream.write(text)
                digest.update(b'\n'); count += 1; stream.write('\n')
                stream.flush(); os.fsync(stream.fileno())
            written = os.fstat(descriptor)
            cache.need(node(written) == node(original) and written.st_size == count and
                       identity(written) == identity(os.stat(temporary, dir_fd=directory,
                                                            follow_symlinks=False)),
                       'Written observation temporary replaced')
            os.link(temporary, name, src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
            linked = os.fstat(descriptor)
            # link/unlink legitimately changes ctime and nlink, not data/mode.
            stable = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_uid,
                                   info.st_size, info.st_mtime_ns)
            cache.need(stable(linked) == stable(written) and linked.st_nlink == 2 and
                       identity(linked) == identity(os.stat(name, dir_fd=directory, follow_symlinks=False)) ==
                       identity(os.stat(temporary, dir_fd=directory, follow_symlinks=False)),
                       'Observation publication differs from written inode')
            os.unlink(temporary, dir_fd=directory)
            final = os.fstat(descriptor)
            cache.need(final.st_nlink == 1 and stable(final) == stable(written) and
                       identity(final) == identity(os.stat(name, dir_fd=directory, follow_symlinks=False)),
                       'Published observation replaced')
            expected = {'kind': 'file', 'path': name, 'mode': 0o600, 'sizeBytes': count,
                        'sha256': digest.hexdigest()}
            file_record(directory, name, name, final, expected)
            os.fsync(directory)
            return expected['sha256']
        finally:
            try:
                current = os.stat(temporary, dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                if (current.st_dev, current.st_ino) == (original.st_dev, original.st_ino):
                    os.unlink(temporary, dir_fd=directory)
            os.close(descriptor)
            os.fsync(directory)


def prepare(*, artifacts: Path, source: Path, terminal_name: str, terminal_sha256: str,
            final_name: str, final_sha256: str, compact_name: str, compact_sha256: str,
            tool_hashes: dict[str, str]) -> dict[str, Any]:
    require_tools(tool_hashes)
    state = postbuild.bound_document(artifacts, terminal_name, terminal_sha256, 64*1024)
    postbuild.require_terminal(state)  # Before inventory parsing or source observation.
    log = cache.read_source_file(artifacts, 'm156-native-build-attempt-4.log', 256*1024*1024)
    cache.need(len(log) == state['logBytes'] and hashlib.sha256(log).hexdigest() == state['logSHA256'],
               'Terminal build log differs')
    started = datetime.now(timezone.utc).isoformat()
    full = postbuild.bound_document(artifacts, final_name, final_sha256, 512*1024*1024)
    compact = postbuild.bound_document(artifacts, compact_name, compact_sha256, 64*1024)
    cache.need(postbuild.compact(full) == compact, 'Observed full and compact bindings differ')
    git_identity(source, full)
    observation = observe_tree(source, full)
    # The excluded output tree is separately restricted to the exact frozen args.
    with anchored_root(source):
        args_hash = hashlib.sha256(cache.read_source_file(source, postbuild.ARGS_NAME, 1024*1024)).hexdigest()
        version = cache.read_source_file(source, 'chrome/VERSION', 1024).decode('ascii')
    values = dict(line.split('=', 1) for line in version.splitlines() if '=' in line)
    cache.need('.'.join(values[key] for key in ('MAJOR', 'MINOR', 'BUILD', 'PATCH')) == cache.VERSION
               and args_hash == postbuild.ARGS_SHA256, 'Observed VERSION or frozen args differ')
    git_identity(source, full)
    require_tools(tool_hashes)
    return {'schemaVersion': 1, 'status': 'independently-observed-source-only',
            'observerStartedAt': started, 'observerFinishedAt': datetime.now(timezone.utc).isoformat(),
            'chromiumVersion': cache.VERSION, 'officialChromiumBase': full['officialChromiumBase'],
            'terminalStateSHA256': terminal_sha256, 'terminalLogSHA256': state['logSHA256'],
            'originalFreezeSHA256': postbuild.FREEZE_SHA256,
            'observedFullSHA256': final_sha256, 'observedCompactSHA256': compact_sha256,
            'deletedPathCount': len(full['deletedPaths']), 'argsGN': full['argsGN'],
            'reviewedVerifierToolHashes': tool_hashes, **observation,
            'sourceExecution': False, 'atomicFilesystemSnapshot': False,
            'exclusiveSourceCustodyRequired': True, 'freshProducerLaunchBindingStillRequired': True,
            'binaryBindingVerified': False, 'runtimeQualified': False, 'releaseReady': False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('artifacts', 'source', 'terminal-name', 'terminal-sha256', 'final-name',
                 'final-sha256', 'compact-name', 'compact-sha256', 'tool-hashes', 'output'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    result = prepare(artifacts=Path(args.artifacts), source=Path(args.source),
                     terminal_name=args.terminal_name, terminal_sha256=args.terminal_sha256,
                     final_name=args.final_name, final_sha256=args.final_sha256,
                     compact_name=args.compact_name, compact_sha256=args.compact_sha256,
                     tool_hashes=projection.strict_json(args.tool_hashes.encode()))
    output = Path(args.output)
    write_observation_document(output.parent, output.name, result)
    print('Full M156 source observed; producer/binary/runtime/release bindings remain open')


if __name__ == '__main__':
    try:
        main()
    except (cache.M156CacheError, OSError, ValueError, KeyError, subprocess.SubprocessError):
        sys.stderr.write('M156 full source observation refused; no qualification produced.\n')
        raise SystemExit(1) from None
