"""Copy the authenticated M156 source proof, never private build receipts."""
from pathlib import Path
import argparse
import shutil
import chromium_15612_release_evidence as source


def names(project: Path) -> list[str]:
    root = project / 'runtime'
    proof = root / (source.PREFIX + '-source-evidence')
    source.evidence_documents(proof)
    result = [source.PREFIX + '-' + suffix + '.json' for suffix in (
        'source-contract', 'source-input-manifest', 'source-snapshot',
        'rebase-plan', 'port-candidate', 'toolchain-lock')]
    for path in sorted(proof.rglob('*')):
        if path.is_symlink():
            raise ValueError('M156 proof contains a symlink')
        if path.is_file():
            result.append(path.relative_to(root).as_posix())
        elif not path.is_dir():
            raise ValueError('M156 proof contains a special file')
    return result


def process(project: Path, evidence: Path, lock: dict, *, copy: bool = False) -> None:
    candidate = source.read_object(project / 'runtime' / (source.PREFIX + '-port-candidate.json'), 'M156 candidate')
    source.verify_candidate_lock(lock, provenance=candidate, project_root=project)
    if evidence.is_symlink() or not evidence.is_dir():
        raise ValueError('Evidence root must be an existing regular directory')
    for relative in names(project):
        src = source.safe_relative_regular(project / 'runtime', relative)
        dst = evidence / relative
        if any(p.is_symlink() for p in (dst, *dst.parents) if p == evidence or p.is_relative_to(evidence)):
            raise ValueError('Packaged M156 evidence crosses a symlink')
        if copy:
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                with src.open('rb') as reader, dst.open('xb') as writer:
                    shutil.copyfileobj(reader, writer)
        if source.sha256_file(source.safe_relative_regular(evidence, relative)) != source.sha256_file(src):
            raise ValueError('Packaged M156 evidence differs: ' + relative)
    source.evidence_documents(evidence / (source.PREFIX + '-source-evidence'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('lock', type=Path)
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--copy', action='store_true')
    args = parser.parse_args()
    try:
        process(Path(__file__).resolve().parents[1], args.evidence,
                source.read_object(args.lock, 'M156 lock'), copy=args.copy)
    except (OSError, ValueError) as error:
        parser.exit(1, 'M156 packaged evidence rejected: ' + str(error) + '\n')
