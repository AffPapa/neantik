"""Explicit reviewed M156 identities; a version or marker is not qualification."""
from pathlib import Path
from dataclasses import dataclass
import chromium_15612_release_evidence as legacy

FONT_VARIANT = 'font-system-v1'
FONT_PREFIX = 'chromium-15612-font-system-v1'
SECURITY_VARIANT = 'font-system-security-20261015-v1'
SECURITY_PREFIX = 'chromium-15612-' + SECURITY_VARIANT
COMPONENT_VARIANT = 'component-completion-v1'
COMPONENT_PREFIX = 'chromium-15612-' + COMPONENT_VARIANT
SUCCESSOR_PREFIXES = (FONT_PREFIX, SECURITY_PREFIX, COMPONENT_PREFIX)


@dataclass(frozen=True)
class SourceVariant:
    prefix: str
    output: str
    contract_schema: int


_VARIANTS = {
    None: SourceVariant(legacy.PREFIX, 'NeAntikM156Qualified20261009', 2),
    FONT_VARIANT: SourceVariant(FONT_PREFIX, 'NeAntikFontSkiaQA_20261016a', 3),
    SECURITY_VARIANT: SourceVariant(SECURITY_PREFIX, 'NeAntikSecurityQA_20261016', 4),
    COMPONENT_VARIANT: SourceVariant(COMPONENT_PREFIX, 'NeAntikComponentQA_20261016', 5),
}
_SUCCESSOR_FIELDS = frozenset({
    'baseSourceContractSHA256', 'baseSourceSnapshotSHA256',
    'baseFullFDObservationSHA256', 'sourceDeltaProofSHA256', 'securityPatchManifestSHA256',
    'overlayManifestPins',
})


def prefix_for(document: dict) -> str:
    if not isinstance(document, dict):
        raise legacy.M15612EvidenceError('M156 variant document must be an object')
    if 'sourceVariant' in document:
        marker = document['sourceVariant']
        if not isinstance(marker, str) or marker not in _VARIANTS:
            raise legacy.M15612EvidenceError('Unknown M156 source variant')
        prefix = _VARIANTS[marker].prefix
    else:
        if _SUCCESSOR_FIELDS.intersection(document):
            raise legacy.M15612EvidenceError('M156 successor marker is missing')
        prefix = legacy.PREFIX
    for key, suffix in (('sourceContract', '-source-contract.json'),
                        ('sourceProvenance', '-port-candidate.json')):
        if key in document and document[key] != 'runtime/' + prefix + suffix:
            raise legacy.M15612EvidenceError('M156 source paths do not match its explicit variant')
    return prefix


def descriptor_for(document: dict) -> SourceVariant:
    """Closed source-selected metadata; JSON cannot choose a verifier/module."""
    prefix_for(document)
    return _VARIANTS[document.get('sourceVariant')]


def reviewed_lock_prefix(lock: dict) -> str:
    prefix = prefix_for(lock)
    if (lock.get('sourceContract') != 'runtime/' + prefix + '-source-contract.json' or
            lock.get('sourceProvenance') != 'runtime/' + prefix + '-port-candidate.json'):
        raise legacy.M15612EvidenceError('M156 lock needs both reviewed variant paths')
    return prefix


def _subject(document: dict):
    prefix = prefix_for(document)
    if prefix == legacy.PREFIX:
        return legacy
    if prefix == SECURITY_PREFIX:
        import chromium_15612_security_release_evidence as security
        return security
    if prefix == COMPONENT_PREFIX:
        import chromium_15612_component_release_evidence as component
        return component
    import chromium_15612_font_release_evidence as successor
    return successor


def verify_candidate_document(document: dict, *, project_root: Path,
                              source_root: Path | None = None) -> None:
    _subject(document).verify_candidate_document(document, project_root=project_root,
                                                 source_root=source_root)


def verify_candidate_lock(lock: dict, *, provenance: dict, project_root: Path) -> None:
    if reviewed_lock_prefix(lock) != prefix_for(provenance):
        raise legacy.M15612EvidenceError('Mismatched M156 lock/candidate variants')
    _subject(provenance).verify_candidate_lock(lock, provenance=provenance, project_root=project_root)


def verify_unsigned_binary_binding(app: Path, args_gn: Path, document: dict) -> None:
    _subject(document).verify_unsigned_binary_binding(app, args_gn, document)


def report_source_fields(lock: dict, *, project_root: Path) -> dict:
    """Authenticate the source proof before describing its observation scope.

    This does not observe a live source tree or qualify a signed release.
    Historical final9 reports keep their original fields byte for byte.
    """
    prefix = reviewed_lock_prefix(lock)
    candidate = legacy.read_object(project_root / 'runtime' / (prefix + '-port-candidate.json'), 'M156 candidate')
    verify_candidate_lock(lock, provenance=candidate, project_root=project_root)
    if prefix == legacy.PREFIX:
        return {
            'sourceEvidenceMode': 'executed-final9-preserved-build-and-current-packaging-inputs',
            'fullFDObservationSHA256': 'd6836d97a7a24d370663976063516306bfc646c826149f579a319fdb5578722c',
            'freshWholeSourceTreeObserved': False,
        }
    successor = _subject(lock)
    proof = legacy.bound(project_root / 'runtime', prefix + '-source-proof.json', successor.PROOF_SHA256)
    security = prefix in (SECURITY_PREFIX, COMPONENT_PREFIX)
    component = prefix == COMPONENT_PREFIX
    return {
        'sourceVariant': lock['sourceVariant'],
        'sourceEvidenceMode': ('executed-component-completion-preserved-build-and-postbuild-fd-source-proof' if component
                              else 'executed-security-backport-preserved-build-and-postbuild-fd-source-proof'
                               if security else 'executed-font-system-v1-preserved-build-and-postbuild-fd-source-proof'),
        'baseFullFDObservationSHA256': (proof['base']['fullFDObservationSHA256']
                                         if security else successor.BASE_FD_SHA256),
        'postbuildFullFDObservationSHA256': proof['postbuildObservation']['receiptSHA256'],
        'sourceDeltaProofSHA256': successor.PROOF_SHA256,
        'freshWholeSourceTreeObserved': False,
    }


def verify_report_source_fields(report: dict, lock: dict, *, project_root: Path) -> None:
    expected = report_source_fields(lock, project_root=project_root)
    keys = {'sourceVariant', 'sourceEvidenceMode', 'fullFDObservationSHA256',
            'baseFullFDObservationSHA256', 'postbuildFullFDObservationSHA256',
            'sourceDeltaProofSHA256', 'freshWholeSourceTreeObserved'}
    actual = {key: report[key] for key in keys if key in report}
    if actual != expected or actual.get('freshWholeSourceTreeObserved') is not False:
        raise legacy.M15612EvidenceError('M156 source evidence mode/binding mismatch')


def verify_signed_runtime_identity(app: Path, lock: dict, *, project_root: Path) -> None:
    """Compare preserved font bytes; signature/native gates remain separate."""
    prefix = reviewed_lock_prefix(lock)
    if prefix not in SUCCESSOR_PREFIXES:
        raise legacy.M15612EvidenceError('Signed successor identity needs an explicit reviewed variant')
    report_source_fields(lock, project_root=project_root)
    successor = _subject(lock)
    proof = legacy.bound(project_root / 'runtime', prefix + '-source-proof.json', successor.PROOF_SHA256)
    import importlib.util
    spec = importlib.util.spec_from_file_location('m156_font_closure_measure',
                                                project_root / 'scripts/verify-direct-update-runtime-pins.py')
    assert spec and spec.loader
    measurement = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(measurement)
    measurement.golden()
    if measurement.measure(app, 'runtime') != proof['signing']['runtimeTree']:
        raise legacy.M15612EvidenceError('Signed font runtime closure differs from preserved qualification')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('lock', type=Path)
    parser.add_argument('--signed-runtime', type=Path,
                        help='Compare exact preserved font bytes; no browser launch or release qualification')
    args = parser.parse_args()
    try:
        lock = legacy.read_object(args.lock, 'M156 variant lock')
        prefix = reviewed_lock_prefix(lock)
        if args.signed_runtime is not None:
            verify_signed_runtime_identity(args.signed_runtime, lock, project_root=Path(__file__).resolve().parents[1])
        print(prefix)
    except (OSError, ValueError) as error:
        parser.exit(1, 'M156 variant rejected: ' + str(error) + '\n')
