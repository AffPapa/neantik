#!/usr/bin/env python3
"""Seal a signed, unqualified manager bundle so native QA can resume without rebuilding."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

from release_candidate_location import validate
from release_source_receipt import capture_release_source, assert_release_source_unchanged

SPEC = importlib.util.spec_from_file_location('prepared_bundle_inventory', Path(__file__).with_name('direct-candidate-manifest.py'))
INVENTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INVENTORY)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate preparation field')
        result[key] = value
    return result


def read(path):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.geteuid() or stat.S_IMODE(s.st_mode) != 0o600 or s.st_nlink != 1 or s.st_size > 32 * 1024 * 1024:
            raise ValueError('Unsafe private preparation receipt')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            value = json.loads(stream.read(), object_pairs_hook=unique_pairs)
        if not isinstance(value, dict) or type(value.get('schemaVersion')) is not int or value['schemaVersion'] != 1:
            raise ValueError('Unsupported preparation receipt')
        return value
    finally:
        os.close(fd)


def write_once(path, value):
    # Write privately, then publish with exclusive link; interrupted writes
    # cannot look like a valid completed stage and old receipts never change.
    fd, temporary = tempfile.mkstemp(prefix='.prepare-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(canonical(value) + b'\n'); stream.flush(); os.fsync(stream.fileno())
        os.link(temporary, path, follow_symlinks=False)
    finally:
        os.unlink(temporary)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def options(environment):
    channel, signer = environment.get('NEANTIK_RELEASE_CHANNEL'), environment.get('NEANTIK_SIGNING_IDENTITY', '').upper()
    if channel not in ('public-alpha', 'production') or not re.fullmatch('[0-9A-F]{40}', signer) or environment.get('NEANTIK_LOCAL_ADHOC', '0') != '0':
        raise ValueError('Explicit Developer ID preparation options required')
    profile = environment.get('NEANTIK_DIRECT_PROVISIONING_PROFILE')
    return {'channel': channel, 'signerSHA1': signer, 'backup': environment.get('NEANTIK_BROWSER_DATA_BACKUP_ENABLED', '0'),
            'provisioningSHA256': hashlib.sha256(Path(profile).read_bytes()).hexdigest() if profile else None}


def source(root):
    snapshot = capture_release_source(root)
    assert_release_source_unchanged(snapshot)
    return snapshot.payload


def bundle(app, expected_signer):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    displayed = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)], check=True, capture_output=True, text=True)
    if not re.search(r'^TeamIdentifier=H6VGU2M6JD$', displayed.stderr, re.M):
        raise ValueError('Unexpected signing team')
    with tempfile.TemporaryDirectory(prefix='.cert-', dir=app.parent) as directory:
        prefix = Path(directory) / 'cert'
        subprocess.run(['/usr/bin/codesign', '--display', '--extract-certificates=' + str(prefix), str(app)], check=True, capture_output=True)
        signer = hashlib.sha1(Path(str(prefix) + '0').read_bytes()).hexdigest().upper()
    if signer != expected_signer:
        raise ValueError('Unexpected signing certificate')
    arch = subprocess.run(['/usr/bin/lipo', '-archs', str(app / 'Contents/MacOS/NeAntik')], check=True, capture_output=True, text=True).stdout.strip()
    if arch != 'arm64':
        raise ValueError('Unexpected manager architecture')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return {'inventorySHA256': digest(INVENTORY.bundle_inventory(app)), 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'architecture': arch, 'signerSHA1': signer}


def stage(operation, project, root, environment=os.environ, source_reader=source, bundle_reader=bundle):
    root = validate(project, root)
    app = root / 'NeAntik.app'
    start_path, receipt_path = root / 'preparation-source.json', root / 'prepared-bundle.json'
    configured = options(environment)
    if operation == 'begin':
        if app.exists() or app.is_symlink():
            raise ValueError('Candidate already exists')
        start = {'schemaVersion': 1, 'kind': 'manager-preparation-source', 'location': root.name,
                 'source': source_reader(project), 'options': configured}
        write_once(start_path, start)
        return {'status': 'preparation-started', 'releaseQualified': False}
    start = read(start_path)
    if set(start) != {'schemaVersion', 'kind', 'location', 'source', 'options'} or start['kind'] != 'manager-preparation-source' or start['location'] != root.name:
        raise ValueError('Invalid preparation source receipt')
    if canonical(start['source']) != canonical(source_reader(project)) or canonical(start['options']) != canonical(configured):
        raise ValueError('Preparation source or options changed; preserve candidate')
    current = {'schemaVersion': 1, 'kind': 'signed-manager-preparation', 'location': root.name,
               'sourceSHA256': digest(start), 'bundle': bundle_reader(app, configured['signerSHA1']), 'releaseQualified': False}
    if operation == 'finish':
        write_once(receipt_path, current)
    elif operation in ('verify', 'reserve-enrollment'):
        if canonical(read(receipt_path)) != canonical(current):
            raise ValueError('Prepared bundle changed; preserve candidate')
    else:
        raise ValueError('Unknown preparation operation')
    if operation == 'reserve-enrollment':
        marker = root / 'prepared-enrollment-attempt.json'
        output = root / 'fingerprint-enrollment.json'
        attempt = {'schemaVersion': 1, 'kind': 'prepared-enrollment-attempt', 'preparationSHA256': digest(current)}
        if marker.exists() or marker.is_symlink():
            if canonical(read(marker)) != canonical(attempt):
                raise ValueError('Enrollment attempt does not match preparation')
            if not output.exists() or output.is_symlink():
                raise ValueError('Enrollment interrupted; diagnose retained authority before retry')
            status = 'reuse-enrollment'
        else:
            if output.exists() or output.is_symlink():
                raise ValueError('Unbound enrollment output already exists')
            write_once(marker, attempt)
            status = 'new-enrollment'
        return {'status': status, 'releaseQualified': False}
    return {'status': 'signed-bundle-prepared' if operation == 'finish' else 'prepared-bundle-verified', 'releaseQualified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['begin', 'finish', 'verify', 'reserve-enrollment'])
    parser.add_argument('--project-root', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(stage(args.operation, args.project_root, args.root)))
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        # Exception type only: paths, compiler/signature output and credentials
        # stay private. A preparation receipt is never a release approval.
        raise SystemExit('Preparation refused (' + type(error).__name__ + '); retained candidate requires inspection.')


if __name__ == '__main__':
    main()
