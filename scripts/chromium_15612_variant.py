"""Explicit reviewed M156 identities; a version or marker is not qualification."""
from pathlib import Path
import chromium_15612_release_evidence as legacy

FONT_VARIANT = 'font-system-v1'
FONT_PREFIX = 'chromium-15612-font-system-v1'
_SUCCESSOR_FIELDS = frozenset({
    'baseSourceContractSHA256', 'baseSourceSnapshotSHA256',
    'baseFullFDObservationSHA256', 'sourceDeltaProofSHA256',
})


def prefix_for(document: dict) -> str:
    if not isinstance(document, dict):
        raise legacy.M15612EvidenceError('M156 variant document must be an object')
    if 'sourceVariant' in document:
        if document['sourceVariant'] != FONT_VARIANT or not isinstance(document['sourceVariant'], str):
            raise legacy.M15612EvidenceError('Unknown M156 source variant')
        prefix = FONT_PREFIX
    else:
        if _SUCCESSOR_FIELDS.intersection(document):
            raise legacy.M15612EvidenceError('M156 successor marker is missing')
        prefix = legacy.PREFIX
    for key, suffix in (('sourceContract', '-source-contract.json'),
                        ('sourceProvenance', '-port-candidate.json')):
        if key in document and document[key] != 'runtime/' + prefix + suffix:
            raise legacy.M15612EvidenceError('M156 source paths do not match its explicit variant')
    return prefix


def reviewed_lock_prefix(lock: dict) -> str:
    prefix = prefix_for(lock)
    if (lock.get('sourceContract') != 'runtime/' + prefix + '-source-contract.json' or
            lock.get('sourceProvenance') != 'runtime/' + prefix + '-port-candidate.json'):
        raise legacy.M15612EvidenceError('M156 lock needs both reviewed variant paths')
    return prefix


def _subject(document: dict):
    if prefix_for(document) == legacy.PREFIX:
        return legacy
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


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('lock', type=Path)
    args = parser.parse_args()
    try:
        print(reviewed_lock_prefix(legacy.read_object(args.lock, 'M156 variant lock')))
    except (OSError, ValueError) as error:
        parser.exit(1, 'M156 variant rejected: ' + str(error) + '\n')
