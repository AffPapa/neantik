"""Resolve a build's recorded args without assuming M154 uses out/Default."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


def verify_build_args(source_root, args_gn, lock, project_root):
    source_root, args_gn, project_root = map(Path, (source_root, args_gn, project_root))
    version = lock.get('fingerprintChromium', {}).get('chromiumVersion', '')
    relative = 'out/Default/args.gn'
    digest = None
    if version == '154.0.8037.93':
        runtime = project_root / 'runtime'
        snapshot_path = runtime / 'chromium-154-source-snapshot.json'
        contract = json.loads((runtime / 'chromium-154-source-contract.json').read_text())
        if snapshot_path.is_symlink() or hashlib.sha256(snapshot_path.read_bytes()).hexdigest() != contract.get('sourceSnapshotSHA256'):
            raise ValueError('M154 build path snapshot binding mismatch')
        snapshot = json.loads(snapshot_path.read_text())
        relative = snapshot.get('argsGN', {}).get('relativePath', '')
        parts = PurePosixPath(relative).parts
        if len(parts) != 3 or parts[0] != 'out' or parts[1] in {'.', '..'} or parts[2] != 'args.gn' or relative != '/'.join(parts):
            raise ValueError('M154 recorded build path is invalid')
        digest = snapshot['argsGN'].get('sha256')
    expected = source_root / relative
    if (args_gn.is_symlink() or not args_gn.is_file()
            or args_gn.resolve() != expected.resolve()
            or not expected.resolve().is_relative_to(source_root.resolve() / 'out')):
        raise ValueError('Expected canonical build-root args.gn')
    if digest is not None and hashlib.sha256(args_gn.read_bytes()).hexdigest() != digest:
        raise ValueError('M154 build args digest mismatch')
    return expected.resolve()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source_root', type=Path)
    parser.add_argument('args_gn', type=Path)
    parser.add_argument('lock', type=Path)
    args = parser.parse_args()
    try:
        path = verify_build_args(args.source_root, args.args_gn, json.loads(args.lock.read_text()), Path(__file__).resolve().parents[1])
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Build path verification failed: {error}\n')
    print(path)
