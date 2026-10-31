#!/usr/bin/env python3
"""Standalone recipient WebGPU load diagnostic; not browser, legal or release proof.

Ad-hoc mode signs the disposable helper without hardened runtime to allow loading
ad-hoc libraries; it does not represent the security posture of the browser.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

MARKER = b'NEANTIK_RECIPIENT_RELINK_V446_20261028'
SOURCE = Path(__file__).with_suffix('.c')


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def input_file(path: Path, expected: str) -> Path:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError('input must be an absolute regular non-symlink file')
    if not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('expected hash must be lowercase SHA-256')
    if sha(path) != expected:
        raise ValueError('input SHA-256 mismatch')
    return path


def new_output(path: Path) -> Path:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise ValueError('output must be a new absolute path')
    if not path.parent.is_dir() or path.parent.resolve() != path.parent:
        raise ValueError('output parent must exist without symlink components')
    return path


def signing_command(identity: str, name: str, path: Path) -> list[str]:
    # Ad-hoc images do not have a team ID; only the throwaway helper omits
    # hardened runtime. Developer ID keeps runtime and the secure timestamp.
    ad_hoc = identity == '-'
    options = '0' if ad_hoc and name == 'helper' else 'runtime'
    timestamp = '--timestamp=none' if ad_hoc else '--timestamp'
    return ['/usr/bin/codesign', '--force', '--options', options, timestamp,
            '--sign', identity, str(path)]


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build-root', type=Path, required=True, help='Absolute configured WebKit build directory')
    p.add_argument('--span-dylib', type=Path, required=True, help='Absolute path to libswiftCompatibilitySpan.dylib')
    p.add_argument('--output', type=Path, required=True, help='New isolated output directory')
    p.add_argument('--identity', required=True, help='Recipient signing identity, or - for ad-hoc; ad-hoc helper lacks hardened runtime and is a diagnostic only')
    p.add_argument('--webgpu-sha256', required=True)
    p.add_argument('--jsc-sha256', required=True)
    p.add_argument('--span-sha256', required=True)
    return p


def execute(args):
    root = args.build_root
    if not root.is_absolute() or not root.is_dir() or root.is_symlink() or root.resolve() != root:
        raise ValueError('build root must be an absolute directory without symlink components')
    if not args.identity.strip():
        raise ValueError('a signing identity is required')
    ad_hoc = args.identity == '-'
    inputs = {
        'WebGPU': input_file(root / 'WebGPU.framework/Versions/A/WebGPU', args.webgpu_sha256),
        'JavaScriptCore': input_file(root / 'JavaScriptCore.framework/Versions/A/JavaScriptCore', args.jsc_sha256),
        'libswiftCompatibilitySpan.dylib': input_file(args.span_dylib, args.span_sha256),
    }
    if MARKER not in inputs['WebGPU'].read_bytes():
        raise ValueError('WebGPU marker missing')
    output = new_output(args.output)
    if output == root or root in output.parents:
        raise ValueError('output must be outside the source build')
    for ancestor in args.span_dylib.parents:
        if ancestor.suffix == '.app' and (output == ancestor or ancestor in output.parents):
            raise ValueError('output must be outside the source application')
    output.mkdir(mode=0o700)
    report = {'status': 'running', 'scope': 'Same-host signed standalone load only; not browser-host loading, independent recipient, licensing or release qualification. Ad-hoc helper omits hardened runtime and does not model browser security.', 'events': [], 'artifacts': {}}

    def save():
        tmp = output / 'report.json.tmp'
        tmp.write_text(json.dumps(report, indent=2) + '\n')
        tmp.replace(output / 'report.json')

    def run(stage, arguments):
        env = {key: value for key, value in os.environ.items() if not key.startswith('DYLD_')}
        result = subprocess.run(arguments, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        report['events'].append({'stage': stage, 'exitCode': result.returncode,
                                 'stdout': result.stdout[-4000:], 'stderr': result.stderr[-4000:]})
        save()
        if result.returncode:
            raise RuntimeError(stage + ' failed')
        return result

    def verify(path, expected_team, name):
        run('verify:' + path.name, ['/usr/bin/codesign', '--verify', '--strict', str(path)])
        result = run('signature:' + path.name, ['/usr/bin/codesign', '-dvv', str(path)])
        metadata = result.stderr + result.stdout
        team = next((line.split('=', 1)[1] for line in metadata.splitlines() if line.startswith('TeamIdentifier=')), None)
        code_directory = next((line for line in metadata.splitlines() if line.startswith('CodeDirectory ')), '')
        helper_without_runtime = ad_hoc and name == 'helper'
        if helper_without_runtime and 'runtime' in code_directory:
            raise RuntimeError('unexpected hardened runtime for ad-hoc helper')
        if not helper_without_runtime and 'runtime' not in code_directory:
            raise RuntimeError('hardened runtime absent')
        if not ad_hoc and (not team or team == 'not set' or (expected_team and team != expected_team) or 'Timestamp=' not in metadata):
            raise RuntimeError('signature team/timestamp check failed')
        entitlements = run('entitlements:' + path.name, ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(path)]).stdout.encode()
        if entitlements.strip() and plistlib.loads(entitlements):
            raise RuntimeError('unexpected entitlements')
        return team

    try:
        save()
        destinations = {
            'WebGPU': output / 'Frameworks/WebGPU.framework/Versions/A/WebGPU',
            'JavaScriptCore': output / 'Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore',
            'libswiftCompatibilitySpan.dylib': output / 'Frameworks/libswiftCompatibilitySpan.dylib',
        }
        for name, source in inputs.items():
            destination = destinations[name]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            actual = sha(destination)
            if actual != sha(source):
                raise RuntimeError('copy hash mismatch')
            report['artifacts'][name] = {'sourceSHA256': actual}
        save()
        gpu = destinations['WebGPU']
        run('relocate-webgpu', ['/usr/bin/install_name_tool', '-delete_rpath', str(root), '-add_rpath', '@loader_path/../../..', str(gpu)])
        report['artifacts']['WebGPU']['relocatedSHA256'] = sha(gpu)
        probe = output / 'probe'
        run('compile-helper', ['/usr/bin/xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-Wl,-rpath,@executable_path/Frameworks', str(SOURCE), '-o', str(probe)])
        report['helperSourceSHA256'] = sha(SOURCE)
        report['artifacts']['helper'] = {'unsignedSHA256': sha(probe)}
        team = None
        for name, path in [*destinations.items(), ('helper', probe)]:
            run('sign:' + name, signing_command(args.identity, name, path))
            report['artifacts'][name]['signedSHA256'] = sha(path)
            team = verify(path, team, name)
        if MARKER not in gpu.read_bytes():
            raise RuntimeError('marker lost during signing')
        before = {name: sha(path) for name, path in destinations.items()}
        run('dlopen-exact-signed-images', [str(probe), str(gpu), str(destinations['JavaScriptCore'])])
        if before != {name: sha(path) for name, path in destinations.items()}:
            raise RuntimeError('images changed during load')
        report['signingMode'] = 'ad-hoc' if ad_hoc else 'developer-id'
        report['status'] = 'SAME_HOST_SIGNED_STANDALONE_DLOPEN_PASS'
        report['imagesUnchangedDuringRun'] = True
        save()
    except Exception as error:
        report['status'] = 'FAILED'; report['failure'] = str(error)
        save()
        raise
    return output / 'report.json'


def main():
    try:
        report = execute(parser().parse_args())
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
        print('recipient diagnostic failed:', error, file=sys.stderr)
        return 1
    print(json.dumps({'status': 'SAME_HOST_SIGNED_STANDALONE_DLOPEN_PASS', 'report': str(report)}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
