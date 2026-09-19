"""Select packaged source contracts by recorded hash, never by newest filename."""
import hashlib
from pathlib import Path
import re


CONTRACT_NAMES = ('chromium-152-source-contract.json', 'chromium-153-source-contract.json')


def select_contract(directory: Path, expected_sha256: str) -> Path:
    directory = Path(directory)
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError('Source contract directory missing or unsafe')
    if not isinstance(expected_sha256, str) or not re.fullmatch('[0-9a-f]{64}', expected_sha256):
        raise ValueError('Source contract SHA-256 required')
    matches = []
    for name in CONTRACT_NAMES:
        path = directory / name
        if path.is_symlink():
            raise ValueError('Symlinked source contract is not allowed')
        if not path.exists():
            continue
        if not path.is_file():
            raise ValueError('Source contract must be a regular file')
        if hashlib.sha256(path.read_bytes()).hexdigest() == expected_sha256:
            matches.append(path)
    if len(matches) != 1:
        raise ValueError('Exactly one source contract must match the recorded SHA-256')
    return matches[0]


def main():
    import argparse
    import json
    import sys
    from gclient_input_bundle import unique_object
    from runtime_source_provenance import verify_contract
    parser = argparse.ArgumentParser(description='Select and validate the source contract/plan bound to a candidate.')
    parser.add_argument('project_root', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--field', choices=('contract', 'plan', 'patch-manifest'), required=True)
    args = parser.parse_args()
    try:
        if not args.candidate.is_file() or args.candidate.is_symlink():
            raise ValueError('Candidate must be a regular nonsymlink file')
        candidate = json.loads(args.candidate.read_bytes(), object_pairs_hook=unique_object)
        if not isinstance(candidate, dict):
            raise ValueError('Candidate must be an object')
        digest = candidate.get('sourceContractSHA256', candidate.get('contractSHA256'))
        contract = select_contract(args.project_root / 'runtime', digest)
        plan = contract.parent / {'chromium-152-source-contract.json': 'chromium-152-rebase-plan.json',
                                  'chromium-153-source-contract.json': 'chromium-153-gclient-plan.json'}[contract.name]
        checked = verify_contract(project_root=args.project_root, contract_path=contract, rebase_plan_path=plan)
        if args.field == 'patch-manifest':
            name = 'series-153.json' if checked['sourceMode'] == 'gclient' else 'series.json'
            manifest = args.project_root / 'runtime/nevision-patches' / name
            expected = candidate.get('ownedManifests', {}).get('neantikPatchSeriesSHA256')
            if manifest.is_symlink() or not manifest.is_file() or hashlib.sha256(manifest.read_bytes()).hexdigest() != expected:
                raise ValueError('Candidate patch manifest hash mismatch')
            print(manifest)
        else:
            print(contract if args.field == 'contract' else plan)
        return 0
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
