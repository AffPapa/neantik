#!/usr/bin/env python3
"""Prove selected retained Node package bytes against the pinned M156 DEPS.

No extraction, source execution, network or live-source scan. Package member
origins are separate from their later patches/domain substitution and from
the final source/build/runtime contract.
"""
from __future__ import annotations
import ast
import hashlib
import posixpath
import tarfile
from typing import Any, BinaryIO
from chromium_15612_generated_cache import HASH, need, relative_path
from chromium_15612_postbuild import canonical_digest

DEPS_SHA256 = 'b4de748ba5abac43952bdc0945795d9c3a07238d18b37ae0f82231669f68fc94'
PREFIX = 'third_party/node/node_modules/'
ARCHIVE_SHA256 = '146cb2af600aa8cf80635592b65219fc94ff3deb384a46a41261405feb46c228'
ARCHIVE_SIZE = 11312049
OBJECT = {'object_name': '44f845cd5bd9d805cb1c73a98d5726b38ed8662a',
          'sha256sum': ARCHIVE_SHA256, 'size_bytes': ARCHIVE_SIZE,
          'generation': 1789349489677960, 'output_file': 'node_modules.tar.gz'}
MAX_MEMBERS = 50_000
MAX_EXPANDED = 512*1024**2
MAX_SELECTED = 32*1024**2


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def official_object(raw: bytes) -> dict[str, Any]:
    """Read only the literal package stanza; never execute DEPS."""
    need(isinstance(raw, bytes) and len(raw) <= 512*1024 and sha(raw) == DEPS_SHA256,
         'Exact official DEPS bytes required')
    tree = ast.parse(raw.decode('utf8'))
    matches = [n for n in tree.body if isinstance(n, ast.Assign) and
               any(isinstance(t, ast.Name) and t.id == 'deps' for t in n.targets)]
    need(len(matches) == 1 and len(matches[0].targets) == 1 and isinstance(matches[0].value, ast.Dict),
         'One literal DEPS dictionary required')
    deps, seen, selected = matches[0].value, set(), []
    for key, value in zip(deps.keys, deps.values, strict=True):
        need(isinstance(key, ast.Constant) and type(key.value) is str and key.value not in seen,
             'Dynamic or duplicate DEPS key refused')
        seen.add(key.value)
        if key.value == 'src/'+PREFIX[:-1]: selected.append(value)
    need(len(selected) == 1, 'Exact Node dependency missing')
    value = ast.literal_eval(selected[0])
    need(value == {'bucket': 'chromium-nodejs', 'dep_type': 'gcs', 'condition': 'non_git_source',
                   'objects': [OBJECT]} and type(value['objects'][0]['size_bytes']) is int and
         type(value['objects'][0]['generation']) is int, 'Official Node package tuple differs')
    return {'DEPS_SHA256': DEPS_SHA256, 'bucket': 'chromium-nodejs', **OBJECT,
            'serverGenerationObserved': False}


def archive_hash(stream: BinaryIO) -> str:
    stream.seek(0); digest = hashlib.sha256(); remaining = ARCHIVE_SIZE
    while remaining:
        chunk = stream.read(min(1024*1024, remaining))
        need(bool(chunk), 'Official Node archive is truncated')
        digest.update(chunk); remaining -= len(chunk)
    need(not stream.read(1), 'Official Node archive exceeds exact size')
    return digest.hexdigest()


def member_name(value: str) -> str | None:
    need(isinstance(value, str) and 0 < len(value) <= 4096, 'Unbounded Node member name')
    if value in {'.', './'}: return None
    return relative_path(value[2:] if value.startswith('./') else value)


def verify_archive(stream: BinaryIO, requested: dict[str, str]) -> dict[str, Any]:
    """Observe exact selected original payloads, never install/extract them."""
    need(isinstance(requested, dict) and 0 < len(requested) <= 1000,
         'Bounded selected Node origin map required')
    targets = {}
    for path, digest in requested.items():
        relative_path(path)
        need(path.startswith(PREFIX) and path != PREFIX+'node_modules.tar.gz' and
             isinstance(digest, str) and HASH.fullmatch(digest), 'Invalid selected Node origin')
        targets[relative_path(path[len(PREFIX):])] = digest
    need(archive_hash(stream) == ARCHIVE_SHA256, 'Official Node archive hash differs')
    stream.seek(0); members, observed, total = {}, {}, 0
    with tarfile.open(fileobj=stream, mode='r|gz') as archive:
        for member in archive:
            name = member_name(member.name)
            need(name not in members and len(members) < MAX_MEMBERS and
                 type(member.size) is int and 0 <= member.size <= MAX_EXPANDED and
                 member.sparse is None, 'Duplicate, sparse or excessive Node member')
            if name is None:
                need(member.isdir() and member.size == 0 and not member.linkname,
                     'Invalid Node archive root')
                kind = 'directory'
            elif member.type in {tarfile.REGTYPE, tarfile.AREGTYPE}:
                need(not member.linkname, 'Node file has link metadata')
                kind = 'file'
            elif member.isdir():
                need(member.size == 0 and not member.linkname, 'Invalid Node directory')
                kind = 'directory'
            elif member.issym():
                need(member.size == 0 and isinstance(member.linkname, str) and
                     0 < len(member.linkname) <= 4096 and not member.linkname.startswith('/') and
                     '\\' not in member.linkname and '\0' not in member.linkname,
                     'Unsafe Node package link')
                relative_path(posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname)))
                kind = 'symlink'
            else:
                need(False, 'Unsupported Node archive member type')
            total += member.size; need(total <= MAX_EXPANDED, 'Node expanded bytes exceed bound')
            members[name] = kind
            if name in targets:
                need(kind == 'file' and member.size <= MAX_SELECTED, 'Selected Node origin is not a bounded file')
                content = archive.extractfile(member)
                need(content is not None, 'Selected Node payload unavailable')
                with content: raw = content.read(member.size+1)
                need(len(raw) == member.size and sha(raw) == targets[name], 'Node pristine payload digest differs')
                observed[PREFIX+name] = sha(raw)
    need(set(observed) == set(requested), 'Selected Node payload coverage differs')
    for path in targets:
        parent = posixpath.dirname(path)
        while parent:
            need(members.get(parent) == 'directory', 'Selected Node path traverses missing/non-directory parent')
            parent = posixpath.dirname(parent)
    need(archive_hash(stream) == ARCHIVE_SHA256, 'Node archive changed during observation')
    return {'schemaVersion': 1, 'status': 'selected-pinned-node-package-origins-observed-only',
            'archiveSHA256': ARCHIVE_SHA256, 'archiveSizeBytes': ARCHIVE_SIZE,
            'selectedPayloadCount': len(observed), 'selectedPayloads': observed,
            'selectedPayloadsSHA256': canonical_digest(observed), 'archiveMemberCount': len(members),
            'expandedBytes': total, 'archiveExtracted': False, 'sourceExecution': False,
            'finalLiveSourceBindingStillRequired': True, 'runtimeQualified': False, 'releaseReady': False}
