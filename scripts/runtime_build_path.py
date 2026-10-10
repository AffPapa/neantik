"""Resolve a build's recorded args without assuming M154 uses out/Default."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


def verify_build_args(source_root, args_gn, lock, project_root):
    source_root, args_gn, project_root = map(Path, (source_root, args_gn, project_root))
    fingerprint = lock.get('fingerprintChromium')
    version = fingerprint.get('chromiumVersion') if isinstance(fingerprint, dict) else None
    if (not isinstance(version, str) or len(version) > 40
            or len(version.split('.')) != 4
            or any(not part or not part.isascii() or not part.isdecimal()
                   for part in version.split('.'))):
        raise ValueError('Invalid Chromium build path version')
    relative = 'out/Default/args.gn'
    digest = None
    m154_evidence = {
        '154.0.8037.93': 'chromium-154',
        '154.0.8037.98': 'chromium-15498',
        '155.0.8059.40': 'chromium-15540',
        '156.0.8078.12': 'chromium-15612',
    }
    # Every newer port needs its own reviewed source/args binding. Never let
    # an unknown major silently use the historical out/Default convention.
    if int(version.split('.')[0]) >= 154 and version not in m154_evidence:
        raise ValueError('Unsupported Chromium build path version')
    if version in m154_evidence:
        runtime = project_root / 'runtime'
        evidence_prefix = m154_evidence[version]
        if version == '156.0.8078.12':
            expected_m156=source_root/'out/NeAntikM156Qualified20261009/args.gn'
            if args_gn != expected_m156 or args_gn.is_symlink():
                raise ValueError('Expected exact M156 qualified build args path')
            from chromium_15612_release_evidence import verify_candidate_lock
            provenance=json.loads((runtime/'chromium-15612-port-candidate.json').read_text())
            verify_candidate_lock(lock,provenance=provenance,project_root=project_root)
        if version == '155.0.8059.40':
            from chromium_15540_variant import prefix_for,verify_candidate_lock
            evidence_prefix=prefix_for(lock)
            expected_contract='runtime/'+evidence_prefix+'-source-contract.json'
            if lock.get('sourceContract')!=expected_contract:raise ValueError('M155 build path lock/variant mismatch')
            if evidence_prefix!='chromium-15540':
                provenance=json.loads((runtime/(evidence_prefix+'-port-candidate.json')).read_text())
                verify_candidate_lock(lock,provenance=provenance,project_root=project_root)
        snapshot_path = runtime / f'{evidence_prefix}-source-snapshot.json'
        contract = json.loads((runtime / f'{evidence_prefix}-source-contract.json').read_text())
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
