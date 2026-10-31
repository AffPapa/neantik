#!/usr/bin/env python3
"""Verify a recipient resigner's source/signed image correspondence.

This is a local byte-and-signature check, not a build/source attestation,
notice approval, browser-host load, or permission to distribute an artifact.
It does not change the production runtime verifier or accept a release override.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('neantik_recipient_resign', ROOT / 'resign-webkit-recipient-runtime.py')
if SPEC is None or SPEC.loader is None:
    raise RuntimeError('recipient runtime helper unavailable')
RESIGN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RESIGN
SPEC.loader.exec_module(RESIGN)


class LineageError(ValueError):
    pass


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def image_hashes(path: Path) -> dict[str, str]:
    root = RESIGN._validate_tree(path)
    return {p.relative_to(root).as_posix(): sha256(p)
            for p in RESIGN._macho_files(root)}


def compare_baseline(source_hashes: dict[str, str], receipt_path: Path, expected_sha256: str) -> dict:
    """Compare actual inputs to one explicitly pinned baseline; not a build attestation."""
    if (receipt_path.is_symlink() or not receipt_path.is_file() or receipt_path.stat().st_size > 2_000_000
            or not re.fullmatch(r'[0-9a-f]{64}', expected_sha256)
            or sha256(receipt_path) != expected_sha256):
        raise LineageError('baseline receipt identity mismatch')
    try:
        receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
        rows = receipt['outputs']
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise LineageError('baseline receipt unreadable') from error
    if not isinstance(rows, list) or not 1 <= len(rows) <= 128:
        raise LineageError('baseline outputs invalid')
    baseline = {}
    for row in rows:
        if not isinstance(row, dict):
            raise LineageError('baseline output invalid')
        name, digest = row.get('path'), row.get('sha256')
        if (not isinstance(name, str) or not name or '\\' in name or Path(name).is_absolute()
                or '..' in Path(name).parts or name in baseline
                or not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest)):
            raise LineageError('baseline output invalid')
        baseline[name] = digest
    if not set(baseline).issubset(source_hashes):
        raise LineageError('baseline output absent from source images')
    return {'receiptSHA256': expected_sha256, 'comparedCount': len(baseline),
            'differentImages': sorted(name for name, digest in baseline.items() if source_hashes[name] != digest),
            'additionalSourceImages': sorted(set(source_hashes) - set(baseline)),
            'scope': 'hash comparison only; does not establish build provenance or legal sufficiency'}


def verify_lineage(source: Path, signed: Path, binding_path: Path, team: str,
                   baseline_receipt: Path | None = None, baseline_sha256: str | None = None) -> dict:
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise LineageError('expected team must be a 10-character identifier')
    if binding_path.is_symlink() or not binding_path.is_file() or binding_path.stat().st_size > 2_000_000:
        raise LineageError('binding must be a physical bounded file')
    try:
        binding = json.loads(binding_path.read_text(encoding='utf-8'))
    except (OSError, UnicodeError, ValueError) as error:
        raise LineageError('binding is unreadable') from error
    rows = binding.get('images') if isinstance(binding, dict) else None
    if (not isinstance(rows, list) or binding.get('schemaVersion') != 1
            or binding.get('status') != 'recipient-signed-runtime-image-binding'
            or not 1 <= len(rows) <= 128 or binding.get('imageCount') != len(rows)):
        raise LineageError('binding schema invalid')
    source_hashes, signed_hashes = image_hashes(source), image_hashes(signed)
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise LineageError('binding row invalid')
        name = row.get('path')
        if (not isinstance(name, str) or not name or '\\' in name
                or Path(name).is_absolute() or '..' in Path(name).parts or name in seen):
            raise LineageError('binding path invalid')
        seen.add(name)
        for key in ('sourceInputSHA256', 'relocatedSHA256', 'recipientSignedSHA256'):
            if not isinstance(row.get(key), str) or not re.fullmatch(r'[0-9a-f]{64}', row[key]):
                raise LineageError('binding digest invalid')
        if (source_hashes.get(name) != row['sourceInputSHA256']
                or signed_hashes.get(name) != row['recipientSignedSHA256']):
            raise LineageError('runtime image digest mismatch')
    if seen != set(source_hashes) or seen != set(signed_hashes):
        raise LineageError('runtime image inventory mismatch')
    RESIGN.PACKAGER.verify_runtime_frameworks(signed, team)
    RESIGN.PACKAGER.verify_release_xpc_entitlements(signed)
    if (baseline_receipt is None) != (baseline_sha256 is None):
        raise LineageError('baseline path and SHA-256 must be supplied together')
    result = {'schemaVersion': 1, 'status': 'local-image-correspondence-pass',
            'imageCount': len(rows), 'bindingSHA256': sha256(binding_path),
            'expectedTeam': team, 'releaseQualified': False,
            'limitations': ['not source/build provenance', 'not complete notices or license qualification',
                            'not recipient host packaging or browser load', 'not production release authorization']}
    if baseline_receipt is not None:
        result['baselineComparison'] = compare_baseline(source_hashes, baseline_receipt, baseline_sha256)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-frameworks', type=Path, required=True)
    parser.add_argument('--signed-frameworks', type=Path, required=True)
    parser.add_argument('--binding', type=Path, required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--baseline-receipt', type=Path)
    parser.add_argument('--baseline-sha256')
    args = parser.parse_args()
    try:
        print(json.dumps(verify_lineage(args.source_frameworks, args.signed_frameworks, args.binding,
                                       args.team, args.baseline_receipt, args.baseline_sha256), sort_keys=True))
        return 0
    except (LineageError, RESIGN.ResignError, RESIGN.PACKAGER.ContractError, OSError) as error:
        print('Recipient runtime lineage refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
