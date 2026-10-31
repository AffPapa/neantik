#!/usr/bin/env python3
"""Stage a standalone ARM64 QA bundle, not a releasable NeAntik application.

Uses the normalized layout and existing compiled research host. Explicit Mach-O
paths replace environment-based injection. No browser launch or system changes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

FRAMEWORKS = ('JavaScriptCore', 'WebCore', 'WebGPU', 'WebInspectorUI',
              'WebKitLegacy', '_WebKit_SwiftUI', 'WebKit')
MAGIC = {bytes.fromhex(x) for x in ('cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(*args):
    return subprocess.check_output(list(args), text=True, stderr=subprocess.PIPE)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def replacement(path):
    for name in FRAMEWORKS:
        suffix = f'{name}.framework/Versions/A/{name}'
        if path.endswith('/' + suffix):
            return '@rpath/' + suffix
    for name in ('libwebrtc.dylib', 'libANGLE-shared.dylib'):
        if path.endswith('/' + name):
            return '@rpath/' + name
    if path.endswith('/libWebKitSwift.dylib'):
        return '@rpath/WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib'
    return path


def stage(layout, host, upstream_policy, output, receipt):
    if output.exists() or output.is_symlink() or receipt.exists():
        raise ValueError('Preserve existing QA output/receipt')
    from assemble_layout import validate_links, clone
    validate_links(layout)
    contents = output / 'Contents'
    frameworks = contents / 'Frameworks'; frameworks.mkdir(parents=True)
    macos = contents / 'MacOS'; macos.mkdir()
    for name in FRAMEWORKS:
        clone(layout / (name + '.framework'), frameworks / (name + '.framework'))
    for name in ('libANGLE-shared.dylib', 'libwebrtc.dylib'):
        clone(layout / name, frameworks / name)
    resources = contents / 'Resources'; resources.mkdir()
    for name in ('ANGLEMetalLib.metallib', 'shaders'):
        clone(layout / name, resources / name)
    clone(host, macos / 'Host')
    policy = frameworks / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
    policy.write_bytes(upstream_policy.read_bytes())
    info = {'CFBundleExecutable': 'Host', 'CFBundleIdentifier': 'app.neantik.webkit-bundle-qa',
            'CFBundleName': 'NeAntik WebKit Bundle QA', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'LSMinimumSystemVersion': '26.5', 'NSHighResolutionCapable': True,
            'NSAppTransportSecurity': {'NSAllowsArbitraryLoadsInWebContent': True}}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    binaries = []
    for path in sorted(contents.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MAGIC:
                continue
        before = digest(path)
        archs = run('/usr/bin/lipo', '-archs', str(path)).strip().split()
        if 'arm64' not in archs:
            raise ValueError('No ARM64 slice: ' + str(path.relative_to(contents)))
        if archs != ['arm64']:
            temporary = path.with_name(path.name + '.arm64-staging')
            run('/usr/bin/lipo', str(path), '-thin', 'arm64', '-output', str(temporary))
            temporary.chmod(path.stat().st_mode & 0o777)
            temporary.replace(path)
        dependencies = [line.strip().split(' (')[0] for line in
                        run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]]
        changes = []
        own_id_lines = run('/usr/bin/otool', '-D', str(path)).splitlines()[1:]
        own_id = own_id_lines[0].strip() if own_id_lines else None
        if own_id and replacement(own_id) != own_id:
            run('/usr/bin/install_name_tool', '-id', replacement(own_id), str(path))
        for dependency in dependencies:
            changed = replacement(dependency)
            if changed != dependency:
                run('/usr/bin/install_name_tool', '-change', dependency, changed, str(path))
                changes.append([dependency, changed])
        rpath = '@loader_path/' + os.path.relpath(frameworks, path.parent)
        existing = run('/usr/bin/otool', '-l', str(path))
        if 'path ' + rpath + ' (offset ' not in existing:
            run('/usr/bin/install_name_tool', '-add_rpath', rpath, str(path))
        binaries.append({'path': str(path.relative_to(contents)), 'inputSHA256': before,
                         'unsignedOutputSHA256': digest(path), 'relinked': changes, 'rpath': rpath})
    validate_links(output)
    result = {'schemaVersion': 1, 'status': 'unsigned-standalone-qa-only', 'app': str(output),
              'hostInputSHA256': digest(host), 'policy': 'unmodified-upstream-positive-baseline',
              'policySHA256': digest(upstream_policy), 'binaries': binaries,
              'nativeLaunched': False, 'notarized': False, 'hardenedRuntimeVerified': False}
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'status': result['status'], 'machOCount': len(binaries)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('layout', 'host', 'upstream-policy', 'output', 'receipt'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    stage(args.layout, args.host, args.upstream_policy, args.output, args.receipt)
