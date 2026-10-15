"""Preserved report bytes for one independently pinned signed runtime pair."""
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from chromium_15612_release_evidence import bound, safe_relative_regular, need

NAME = 'chromium-15612-font-system-v1-runtime-verification.json'
SHA256 = '534900f801963f79dfc2e0b7fc9c693c4a06c6b06d9bb34392c59526c53df885'


def frozen_report(project: Path) -> tuple[dict, bytes]:
    report = bound(project / 'runtime', NAME, SHA256)
    raw = safe_relative_regular(project / 'runtime', NAME).read_bytes()
    need(hashlib.sha256(raw).hexdigest() == SHA256, 'Frozen font report changed during read')
    return report, raw


def preserved_report_bytes(observed: dict, project: Path) -> bytes:
    """Fresh byte/signature observations must equal the frozen report inputs.

    Reuse its original creation date; do not manufacture a new timestamp that
    breaks the complete compiled pair or implies a new headed qualification.
    """
    report, raw = frozen_report(project)
    need(set(observed) == set(report), 'Observed font report fields differ')
    created = observed.get('createdAt')
    need(isinstance(created, str) and len(created) <= 64 and created.endswith('Z'), 'Invalid observation date')
    need(datetime.fromisoformat(created).utcoffset() == timezone.utc.utcoffset(None), 'Observation date is not UTC')
    current = {**observed, 'createdAt': report['createdAt']}
    need(current == report, 'Observed font runtime does not match frozen report')
    return raw


def verify_report_file(path: Path) -> None:
    raw = safe_relative_regular(path.parent, path.name).read_bytes()
    need(len(raw) <= 65_536 and hashlib.sha256(raw).hexdigest() == SHA256,
         'Packaged font report differs from preserved compiled binding')


def historical_baseline(project: Path) -> Path:
    from runtime_historical_baseline import bound_baseline_path
    report, _ = frozen_report(project)
    return bound_baseline_path(project / 'runtime', report['securityBaselineSHA256'])


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Resolve the preserved font report baseline; no release authority.')
    parser.add_argument('--baseline', action='store_true', required=True)
    args = parser.parse_args()
    try:
        print(historical_baseline(Path(__file__).resolve().parents[1]))
    except (OSError, ValueError) as error:
        parser.exit(1, 'Frozen font baseline rejected: ' + str(error) + '\n')
