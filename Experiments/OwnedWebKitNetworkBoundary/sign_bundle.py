#!/usr/bin/env python3
"""Sign only the isolated research bundle; no release/notarization claim."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

from assemble_layout import validate_links
from stage_bundle import MAGIC
from probe import IDENTITY


def sign_bundle(app, receipt, fixed_framework_path=False):
    if receipt.exists():
        raise ValueError('Signature receipt exists;preserve previous evidence')
    if app.is_symlink():
        raise ValueError('QA bundle must be physical')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'app.neantik.webkit-bundle-qa':
        raise ValueError('Not the isolated QA identity')
    validate_links(app)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    entitlements_dir = receipt.parent / (receipt.stem + '-entitlements')
    entitlements_dir.mkdir()
    signed = []

    def sign(path):
        relative = path.relative_to(app).as_posix()
        entitlements = {}
        if 'WebContent' in relative or relative.endswith('/Helpers/jsc'):
            entitlements['com.apple.security.cs.allow-jit'] = True
        if fixed_framework_path and (path == app or relative == 'Contents/MacOS/Host'):
            entitlements['com.apple.security.cs.allow-dyld-environment-variables'] = True
        args = ['/usr/bin/codesign', '--force', '--sign', IDENTITY,
                '--options', 'runtime', '--timestamp=none']
        if entitlements:
            file = entitlements_dir / (str(len(signed)) + '.plist')
            file.write_bytes(plistlib.dumps(entitlements))
            args += ['--entitlements', str(file)]
        result = subprocess.run(args + [str(path)], capture_output=True, text=True)
        signed.append({'path': relative, 'exit': result.returncode, 'entitlementKeys': list(entitlements)})
        (receipt.parent / (receipt.stem + '-progress.json')).write_text(json.dumps(signed, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError(result.stderr)

    # Sign every real Mach-O first, including nested JSC command-line helpers.
    # Seal XPC bundles next, then frameworks, then the outer application.
    for path in sorted(app.rglob('*')):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in MAGIC:
                    sign(path)
    for extension in ('*.xpc', '*.framework'):
        for path in sorted(app.rglob(extension), key=lambda p: len(p.parts), reverse=True):
            if not path.is_symlink():
                sign(path)
    sign(app)
    team = 'anchor apple generic and certificate leaf[subject.OU] = "H6VGU2M6JD"'
    result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep', '-R=' + team,
                             str(app)], capture_output=True, text=True)
    receipt.write_text(json.dumps({'status': 'PASS' if result.returncode == 0 else 'FAIL',
                                   'signed': signed, 'strictExit': result.returncode, 'detail': result.stderr,
                                   'secureTimestamp': False, 'notarized': False,
                                   'nativeLaunched': False}, indent=2) + '\n')
    if result.returncode:
        raise RuntimeError(result.stderr)
    print(json.dumps({'status': 'PASS-signature-only', 'signedObjects': len(signed)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--fixed-framework-path', action='store_true')
    args = parser.parse_args()
    sign_bundle(args.app, args.receipt, args.fixed_framework_path)
