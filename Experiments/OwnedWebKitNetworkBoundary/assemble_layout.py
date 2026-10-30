#!/usr/bin/env python3
"""Prepare an unsigned, unqualified runtime copy; never modify research inputs.

The upstream development layout points outside WebKit.framework. Such links
cannot be sealed as nested code. Materialize only the known siblings inside
the framework, retaining the original runtime for comparison and rollback.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate_links(root, allow_empty_framework_alias=False):
    root = root.resolve(strict=True)
    for path in root.rglob('*'):
        if path.is_symlink():
            if (allow_empty_framework_alias and path == root / 'WebCore.framework/Frameworks'
                    and path.readlink().as_posix() == 'Versions/Current/Frameworks'
                    and (root / 'WebCore.framework/Versions/Current').is_symlink()
                    and (root / 'WebCore.framework/Versions/Current').readlink().as_posix() == 'A'
                    and not path.exists()):
                continue
            try:
                path.resolve(strict=True).relative_to(root)
            except (ValueError, OSError, RuntimeError) as error:
                raise ValueError('Broken or escaping runtime symlink: ' + str(path.relative_to(root))) from error


def planned_links(root):
    framework = root / 'WebKit.framework'
    planned = []
    for relative in ['Versions/A/Frameworks/libWebKitSwift.dylib'] + [
            'Versions/A/XPCServices/com.apple.WebKit.' + name + '.xpc'
            for name in ('GPU', 'Model', 'Networking', 'WebContent.CaptivePortal',
                         'WebContent.Development', 'WebContent.EnhancedSecurity', 'WebContent')]:
        path = framework / relative
        if not path.is_symlink() or path.readlink().as_posix() != '../../../../' + path.name:
            raise ValueError('Unexpected upstream nested-code layout: ' + relative)
        target = path.resolve(strict=True)
        if target != (root / path.name).resolve(strict=True):
            raise ValueError('Unexpected nested-code target: ' + relative)
        planned.append((path, target))
    return planned


def clone(source, destination):
    subprocess.run(['/bin/cp', '-cR', str(source), str(destination)], check=True)


def assemble(source, destination, copier=clone):
    source = source.resolve(strict=True)
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError('Output exists; preserve previous assembly')
    if destination.resolve().is_relative_to(source):
        raise ValueError('Output must be outside the source runtime')
    validate_links(source, allow_empty_framework_alias=True)
    planned_links(source)  # Complete preflight before copying or unlinking.
    destination.parent.mkdir(parents=True, exist_ok=True)
    copier(source, destination)
    empty_alias = destination / 'WebCore.framework/Frameworks'
    if empty_alias.is_symlink() and not empty_alias.exists():
        (destination / 'WebCore.framework/Versions/A/Frameworks').mkdir()
    materialized = []
    for path, target in planned_links(destination):
        relative = path.relative_to(destination).as_posix()
        link = path.readlink().as_posix()
        path.unlink()
        copier(target, path)
        materialized.append({'path': relative, 'originalTarget': link})
    stubs = []
    # SDK stubs are unnecessary at runtime. Keep their hashes in the manifest;
    # the full upstream archive and source copy remain unchanged.
    for framework in sorted(destination.glob('*.framework')):
        for path in sorted(framework.rglob('*.tbd'), key=lambda p: p.is_symlink()):
            stubs.append({'path': path.relative_to(destination).as_posix(),
                          'link': str(path.readlink())} if path.is_symlink() else {
                              'path': path.relative_to(destination).as_posix(), 'sha256': sha256(path)})
        for path in list(framework.rglob('*.tbd')):
            path.unlink()
    validate_links(destination)
    for path in (destination / 'WebKit.framework').rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(destination / 'WebKit.framework'):
            raise ValueError('Framework still has an external link')
    return {'schemaVersion': 1, 'status': 'layout-only-unqualified',
            'source': str(source), 'output': str(destination),
            'materialized': materialized, 'omittedSDKStubs': stubs,
            'emptyWebCoreFrameworksContainer': empty_alias.is_symlink(),
            'nativeLaunched': False, 'signed': False, 'notarized': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    if args.receipt.exists():
        parser.error('Receipt exists; preserve previous result')
    receipt = assemble(args.source, args.output)
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'status': receipt['status'], 'materialized': len(receipt['materialized'])}))
