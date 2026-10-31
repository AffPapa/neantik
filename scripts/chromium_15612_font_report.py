"""Preserved report bytes for one independently pinned signed runtime pair."""
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from chromium_15612_release_evidence import bound, safe_relative_regular, need
from chromium_15612_variant import FONT_PREFIX, SECURITY_PREFIX, COMPONENT_PREFIX, SUCCESSOR_PREFIXES, prefix_for

NAME = 'chromium-15612-font-system-v1-runtime-verification.json'
SHA256 = '534900f801963f79dfc2e0b7fc9c693c4a06c6b06d9bb34392c59526c53df885'
SECURITY_NAME = SECURITY_PREFIX + '-runtime-verification.json'
SECURITY_SHA256 = '71b25e291a3fae01f680e98ed9b3a08c9e97e2190fc2d5400d32a92b8c97069e'
COMPONENT_NAME = COMPONENT_PREFIX + '-runtime-verification.json'
COMPONENT_SHA256 = '55206b4fd1f84dd889e0e80737c78325fa257ad4bc67e0eef7cb35c58761ad6c'


def report_policy(prefix: str) -> tuple[str, str]:
    """Only compiled source choices may select a frozen report."""
    if prefix == FONT_PREFIX:
        return NAME, SHA256
    if prefix == SECURITY_PREFIX:
        return SECURITY_NAME, SECURITY_SHA256
    if prefix == COMPONENT_PREFIX:
        return COMPONENT_NAME, COMPONENT_SHA256
    raise ValueError('Unknown preserved M156 successor report')


def frozen_report(project: Path, *, prefix: str = FONT_PREFIX) -> tuple[dict, bytes]:
    name, digest = report_policy(prefix)
    report = bound(project / 'runtime', name, digest)
    raw = safe_relative_regular(project / 'runtime', name).read_bytes()
    need(hashlib.sha256(raw).hexdigest() == digest, 'Frozen successor report changed during read')
    return report, raw


def preserved_report_bytes(observed: dict, project: Path) -> bytes:
    """Fresh byte/signature observations must equal the frozen report inputs.

    Reuse its original creation date; do not manufacture a new timestamp that
    breaks the complete compiled pair or implies a new headed qualification.
    """
    report, raw = frozen_report(project, prefix=prefix_for(observed))
    need(set(observed) == set(report), 'Observed font report fields differ')
    created = observed.get('createdAt')
    need(isinstance(created, str) and len(created) <= 64 and created.endswith('Z'), 'Invalid observation date')
    need(datetime.fromisoformat(created).utcoffset() == timezone.utc.utcoffset(None), 'Observation date is not UTC')
    current = {**observed, 'createdAt': report['createdAt']}
    need(current == report, 'Observed font runtime does not match frozen report')
    return raw


def verify_report_file(path: Path, *, prefix: str = FONT_PREFIX) -> None:
    _, digest = report_policy(prefix)
    raw = safe_relative_regular(path.parent, path.name).read_bytes()
    need(len(raw) <= 65_536 and hashlib.sha256(raw).hexdigest() == digest,
         'Packaged successor report differs from preserved compiled binding')


def historical_baseline(project: Path, *, prefix: str = FONT_PREFIX) -> Path:
    from runtime_historical_baseline import bound_baseline_path
    report, _ = frozen_report(project, prefix=prefix)
    return bound_baseline_path(project / 'runtime', report['securityBaselineSHA256'])


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Resolve the preserved font report baseline; no release authority.')
    parser.add_argument('--baseline', action='store_true', required=True)
    parser.add_argument('--variant-prefix', choices=SUCCESSOR_PREFIXES, default=FONT_PREFIX)
    args = parser.parse_args()
    try:
        print(historical_baseline(Path(__file__).resolve().parents[1], prefix=args.variant_prefix))
    except (OSError, ValueError) as error:
        parser.exit(1, 'Frozen font baseline rejected: ' + str(error) + '\n')
