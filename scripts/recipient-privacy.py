#!/usr/bin/env python3
"""Bounded recipient replay. Default is read-only; never invokes Ninja/signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from chromium_15680_privacy_derivation import (BASE, OUT, MANIFEST, FRAMEWORK, checked_file,
    evidence, verify, verify_contract, thin_members)

PROJECT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_root(path):
    if path is None or not path.is_absolute() or path.is_symlink() or path.resolve() != path:
        raise ValueError('Choose an explicit canonical disposable recipient root (pwd -P)')
    info = path.stat()
    if not path.is_dir() or info.st_uid != os.getuid(): raise ValueError('Recipient root is not owned')
    return path


def source_images(project, root, layer, *, allow_before=False):
    for item in layer['files'] + layer['supplementalSources']:
        relative = item['source']; target = root / relative
        for parent in target.parents:
            if parent == root: break
            if parent.is_symlink() or not parent.is_dir(): raise ValueError('Unsafe source parent')
        if not target.exists() and not target.is_symlink():
            if allow_before and item.get('beforeAbsent') is True: continue
            raise ValueError('Missing recipient source')
        allowed = {item['postimage']['sha256']}
        if allow_before and not item.get('beforeAbsent'): allowed.add(item['preimage']['sha256'])
        if target.is_symlink() or not target.is_file() or sha(target) not in allowed:
            raise ValueError('Source differs from reviewed pre/postimages; preserve local edits')


def apply(project, root, layer):
    source_images(project, root, layer, allow_before=True)
    # Validate every preimage before the first write; a partial own apply can
    # resume, while unrelated edits are never overwritten.
    identity = root.stat()
    for item in layer['files'] + layer['supplementalSources']:
        target = root / item['source']; data = evidence(project, item['postimage']).read_bytes()
        if target.exists() and sha(target) == item['postimage']['sha256']: continue
        if (root.stat().st_dev, root.stat().st_ino) != (identity.st_dev, identity.st_ino): raise ValueError('Root changed')
        descriptor, temporary = tempfile.mkstemp(prefix='.neantik-recipient-', dir=target.parent)
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
            os.chmod(temporary, 0o644)
            if target.is_symlink(): raise ValueError('Source changed to symlink')
            if target.exists() and sha(target) != item['preimage']['sha256']: raise ValueError('Source changed during apply')
            if item.get('beforeAbsent') and target.exists(): raise ValueError('New helper collision')
            os.replace(temporary, target)
        finally: Path(temporary).unlink(missing_ok=True)
    source_images(project, root, layer)


def output_file(root, relative, expected, *, allow_differences=False):
    path = root / relative
    if allow_differences:
        # Exact commands still select the output; a recipient-local build is
        # never converted into published-byte or runtime admission.
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError('Missing or unsafe local output')
        for parent in path.parents:
            if parent == root: break
            if parent.is_symlink() or not parent.is_dir(): raise ValueError('Unsafe output parent')
        return path
    return checked_file(root, relative, expected)


def compiled_sources(project, root, layer, *, allow_differences=False):
    source_images(project, root, layer)
    for item in layer['files']:
        output_file(root, OUT + '/' + item['object'], item['objectSHA256'], allow_differences=allow_differences)


def compile_objects(project, root, layer, *, allow_differences=False):
    source_images(project, root, layer)
    for item in layer['files']:
        recipe = json.loads(evidence(project, item['recipe']).read_text())
        subprocess.run(recipe['argv'], cwd=root / OUT, check=True,
                       env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        output_file(root, OUT + '/' + item['object'], item['objectSHA256'], allow_differences=allow_differences)


def check_archives(project, root, layer, *, allow_differences=False):
    rebuilt = json.loads(evidence(project, layer['link']['archiveRebuilds']).read_text())
    changed = {row['archive'] for row in rebuilt['archives']}
    for name, item in layer['link']['thinArchives'].items():
        archive = output_file(root, OUT + '/' + name, item['sha256'], allow_differences=allow_differences and name in changed)
        expected = json.loads(evidence(project, item['members']).read_text())['members']
        if thin_members(archive.read_bytes()) != expected: raise ValueError('Archive members differ')
    crc = json.loads((project / BASE['portableCRC']['file']).read_text())
    output_file(root, OUT + '/obj/third_party/ffmpeg/ffmpeg_internal/autorename_libavutil_crc.o', crc['outputs']['crcObjectSHA256'], allow_differences=allow_differences)
    checked_file(root, OUT + '/obj/third_party/ffmpeg/libffmpeg_internal.a', crc['outputs']['ffmpegArchiveSHA256'])


def reindex(project, root, layer, *, allow_differences=False):
    compiled_sources(project, root, layer, allow_differences=allow_differences)
    rebuild = json.loads(evidence(project, layer['link']['archiveRebuilds']).read_text())
    out = root / OUT; tool = root / 'third_party/llvm-build/Release+Asserts/bin/llvm-ar'
    if tool.is_symlink() or not tool.is_file(): raise ValueError('Pinned recipient llvm-ar missing')
    for row in rebuild['archives']:
        target = out / row['archive']
        if target.is_symlink() or not target.is_file(): raise ValueError('Unsafe archive')
        if sha(target) == row['afterSHA256']: continue
        if sha(target) != row['beforeSHA256']: raise ValueError('Unreviewed archive preimage')
        descriptor, temporary = tempfile.mkstemp(prefix='.neantik-fresh-archive-', dir=target.parent)
        os.close(descriptor); os.unlink(temporary)
        try:
            subprocess.run([str(tool), *rebuild['flags'], temporary,
                            '@' + str(evidence(project, row['memberInputs']))], cwd=out, check=True)
            if not allow_differences and sha(Path(temporary)) != row['afterSHA256']: raise ValueError('Fresh archive differs')
            expected = json.loads(evidence(project, layer['link']['thinArchives'][row['archive']]['members']).read_text())['members']
            if thin_members(Path(temporary).read_bytes()) != expected: raise ValueError('Fresh archive members differ')
            if sha(target) != row['beforeSHA256']: raise ValueError('Archive changed during reconstruction')
            os.replace(temporary, target)
        finally: Path(temporary).unlink(missing_ok=True)
    # The other six metadata files are unchanged base bytes; no ceremonial ar s.
    check_archives(project, root, layer, allow_differences=allow_differences)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, default=PROJECT)
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--action', choices=['check-only', 'apply', 'compile', 'reindex', 'link', 'verify'], default='check-only')
    parser.add_argument('--confirm-disposable', action='store_true', help='Required for explicit source/output writes')
    parser.add_argument('--allow-byte-differences', action='store_true', help='Recipient-local replay only; report differences caused by SDK/debug paths, never admit as published bytes')
    args = parser.parse_args(argv); project = args.project_root.resolve()
    _, layer = verify_contract(project)
    if args.action == 'check-only':
        print(json.dumps({'pass': True, 'scope': 'reviewed recipe integrity only', 'executed': False})); return 0
    root = source_root(args.source_root)
    if args.action == 'verify':
        compiled_sources(project, root, layer, allow_differences=args.allow_byte_differences)
        check_archives(project, root, layer, allow_differences=args.allow_byte_differences)
        actual = output_file(root, OUT + '/' + FRAMEWORK, layer['link']['frameworkSHA256'], allow_differences=args.allow_byte_differences)
        print(json.dumps({'pass': True, 'scope': 'recipient-local output' if args.allow_byte_differences else 'exact existing recipient bytes', 'executed': False, 'frameworkSHA256': sha(actual), 'matchesPublishedUnsignedFramework': sha(actual) == layer['link']['frameworkSHA256'], 'releaseAuthority': False})); return 0
    if not args.confirm_disposable: raise ValueError('Explicit --confirm-disposable required; preserve production/profile roots')
    if args.action == 'apply': apply(project, root, layer)
    elif args.action == 'compile': compile_objects(project, root, layer, allow_differences=args.allow_byte_differences)
    elif args.action == 'reindex': reindex(project, root, layer, allow_differences=args.allow_byte_differences)
    else:
        compiled_sources(project, root, layer, allow_differences=args.allow_byte_differences)
        check_archives(project, root, layer, allow_differences=args.allow_byte_differences)
        command = evidence(project, layer['link']['recipe']).read_text()
        subprocess.run(['/bin/sh', '-c', command], cwd=root / OUT, check=True,
                       env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        output_file(root, OUT + '/' + FRAMEWORK, layer['link']['frameworkSHA256'], allow_differences=args.allow_byte_differences)
    print(json.dumps({'pass': True, 'action': args.action, 'scope': 'recipient preparation only; not signing or release authority'})); return 0

if __name__ == '__main__':
    try: raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('Recipient replay refused: ' + str(error), file=sys.stderr); raise SystemExit(1)
