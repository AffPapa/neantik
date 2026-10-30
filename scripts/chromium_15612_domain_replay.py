#!/usr/bin/env python3
"""Independently replay retained domain substitutions without touching source.

The caller authenticates the native receipt and holds a stable, no-follow
archive descriptor. This checks cached original bytes and recipe output;
it does not establish their Git/package origin or qualify a runtime.
"""
from __future__ import annotations
import hashlib
import re
import tarfile
import zlib
from typing import BinaryIO, Any
from chromium_15612_generated_cache import HASH, need, relative_path
from chromium_15612_postbuild import canonical_digest

RECIPE_SHA256 = 'f59c4316b4ac32f9dfe4f6440c4cf9ad5dab0ab8827769f5dc2587ca07e91f09'
LIST_SHA256 = '8155b7a9ef7da2122842ba560c19d8c4e8fe10ada2e4af3a4f072bd958a01edc'
MAX_ARCHIVE = 256 * 1024**2
MAX_MEMBER = 32 * 1024**2
MAX_EXPANDED = 2 * 1024**3


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def recipe_pairs(raw: bytes) -> tuple[tuple[re.Pattern, str], ...]:
    # Do not run an arbitrary caller-supplied regex program.
    need(isinstance(raw, bytes) and len(raw) <= 64*1024 and sha(raw) == RECIPE_SHA256,
         'Exact reviewed domain recipe required')
    pairs = []
    for line in filter(None, raw.decode('utf8').splitlines()):
        fields = line.split('#')
        need(len(fields) == 2, 'Domain recipe separator differs')
        pairs.append((re.compile(fields[0]), fields[1]))
    need(len(pairs) == 21, 'Domain recipe coverage differs')
    return tuple(pairs)


def substitute(raw: bytes, pairs: tuple[tuple[re.Pattern, str], ...]) -> tuple[bytes, int]:
    """Preserve upstream UTF-8/Latin-1 and sequential subn semantics in memory."""
    need(isinstance(raw, bytes) and len(raw) <= MAX_MEMBER, 'Domain source bytes exceed bound')
    if not raw:
        return raw, 0
    try:
        content, encoding = raw.decode('utf8'), 'utf8'
    except UnicodeDecodeError:
        content, encoding = raw.decode('latin1'), 'latin1'
    count = 0
    for pattern, replacement in pairs:
        content, changes = pattern.subn(replacement, content)
        count += changes
        need(len(content) <= MAX_MEMBER, 'Domain substitution output exceeds bound')
    result = content.encode(encoding) if count else raw
    need(len(result) <= MAX_MEMBER, 'Domain substitution encoded output exceeds bound')
    return result, count


def archive_digest(stream: BinaryIO) -> str:
    stream.seek(0)
    digest = hashlib.sha256()
    total = 0
    while chunk := stream.read(1024*1024):
        total += len(chunk)
        need(total <= MAX_ARCHIVE, 'Domain cache compressed bytes exceed bound')
        digest.update(chunk)
    need(total > 0, 'Empty domain cache archive')
    return digest.hexdigest()


def verify_archive(stream: BinaryIO, *, expected_archive_sha256: str,
                   recipe: bytes, preimages: dict[str, str], postimages: dict[str, str],
                   unchanged_bytes: dict[str, bytes] | None = None) -> dict[str, Any]:
    """Hash before/after, stream members, never extract or execute source.

    unchanged_bytes, if supplied, must separately have authenticated origin.
    Archive-cache origins and final live-source binding remain caller gates.
    """
    need(isinstance(expected_archive_sha256, str) and HASH.fullmatch(expected_archive_sha256),
         'Pinned domain cache archive digest required')
    need(isinstance(preimages, dict) and 0 < len(preimages) <= 20_000 and
         isinstance(postimages, dict) and set(preimages) == set(postimages),
         'Domain image coverage differs')
    for mapping in (preimages, postimages):
        for name, digest in mapping.items():
            relative_path(name)
            need(isinstance(digest, str) and HASH.fullmatch(digest), 'Invalid domain image digest')
    pairs = recipe_pairs(recipe)
    changed = {n for n in preimages if preimages[n] != postimages[n]}
    unchanged = set(preimages) - changed
    need(unchanged_bytes is None or isinstance(unchanged_bytes, dict),
         'Unchanged domain source bytes must be a map')
    need(archive_digest(stream) == expected_archive_sha256, 'Domain archive digest differs')
    stream.seek(0)
    members, outputs, crc, index = set(), {}, {}, None
    total, substitutions = 0, 0
    with tarfile.open(fileobj=stream, mode='r|gz') as archive:
        for member in archive:
            name = relative_path(member.name)
            # The upstream writer uses PAX for long source paths. Permit
            # exactly that extension, never size/sparse/link overrides.
            pax_path = member.pax_headers
            need(not pax_path or (set(pax_path) == {'path'} and pax_path['path'] == member.name
                                  and len(pax_path['path']) <= 4096),
                 'Unsupported domain cache PAX metadata')
            need(name not in members and len(members) <= len(preimages) and
                 member.type in {tarfile.REGTYPE, tarfile.AREGTYPE} and
                 member.sparse is None and not member.linkname and
                 type(member.size) is int and 0 <= member.size <= MAX_MEMBER,
                 'Unsafe, duplicate or excess domain cache member')
            members.add(name)
            need(name == 'cache_index.list' or
                 (name.startswith('orig/') and name[5:] in preimages),
                 'Unexpected domain cache member')
            total += member.size
            need(total <= MAX_EXPANDED, 'Domain cache expanded bytes exceed bound')
            file = archive.extractfile(member)
            need(file is not None, 'Domain cache member bytes unavailable')
            with file:
                raw = file.read(member.size + 1)
            need(len(raw) == member.size, 'Domain cache member is truncated')
            if name == 'cache_index.list':
                index = raw
                continue
            source_name = name[5:]
            need(sha(raw) == preimages[source_name], 'Cached domain preimage differs')
            result, count = substitute(raw, pairs)
            # Synthetic identity-rule controls cover the upstream behavior:
            # subn count, not byte inequality, decides cache inclusion. The
            # actual pinned short-domain rule adds a suffix, changing bytes.
            need(count > 0 and sha(result) == postimages[source_name],
                 'Independent domain recipe postimage differs')
            outputs[source_name] = sha(result)
            crc[source_name] = f'{zlib.crc32(result):08x}'
            substitutions += count
    cached = set(outputs)
    need(changed <= cached and members == {'cache_index.list'} | {'orig/'+n for n in cached} and index is not None,
         'Domain archive member coverage differs')
    listed = {}
    for line in index.decode('utf8').splitlines():
        fields = line.split('|')
        need(len(fields) == 2 and fields[0] not in listed and fields[0] in cached and
             re.fullmatch('[0-9a-f]{8}', fields[1]), 'Invalid or duplicate domain cache index')
        listed[fields[0]] = fields[1]
    need(listed == crc, 'Domain cache CRC index differs from independent output')
    noncached = set(preimages) - cached
    if unchanged_bytes is not None:
        need(set(unchanged_bytes) == noncached, 'Unchanged domain source coverage differs')
        for name, raw in unchanged_bytes.items():
            need(isinstance(raw, bytes) and sha(raw) == preimages[name],
                 'Unchanged domain preimage differs')
            result, count = substitute(raw, pairs)
            need(count == 0 and result == raw and sha(result) == postimages[name],
                 'Declared unchanged domain source actually substitutes')
    need(archive_digest(stream) == expected_archive_sha256,
         'Domain archive changed during independent replay')
    return {'schemaVersion': 1, 'status': 'independent-domain-cache-replay-verified-only',
            'archiveSHA256': expected_archive_sha256, 'recipeSHA256': RECIPE_SHA256,
            'changedSourceCount': len(changed), 'unchangedSourceCount': len(unchanged),
            'cachedSourceCount': len(cached), 'noncachedSourceCount': len(noncached),
            'unchangedSourcesReplayed': unchanged_bytes is not None or not noncached,
            'substitutionCount': substitutions, 'expandedBytes': total,
            'postimagesSHA256': canonical_digest(outputs),
            'pristineOriginsStillRequired': True, 'finalSourceBindingStillRequired': True,
            'sourceSnapshotVerified': False, 'sourceExecution': False,
            'runtimeQualified': False, 'releaseReady': False}


def verify_schedule(raw: bytes, preimages: dict[str, str], absent: list[dict[str, str]]) -> None:
    need(isinstance(raw, bytes) and len(raw) <= 4*1024**2 and sha(raw) == LIST_SHA256,
         'Exact reviewed domain target list required')
    names = [relative_path(n) for n in raw.decode('utf8').splitlines() if n]
    missing = [relative_path(item['path']) for item in absent]
    need(len(names) == len(set(names)) and len(missing) == len(set(missing)) and
         not set(missing) & set(preimages) and set(names) == set(preimages) | set(missing),
         'Domain target schedule coverage differs')
