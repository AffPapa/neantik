"""Copy the authenticated M156 source proof, never private build receipts."""
from pathlib import Path
import argparse
import shutil
import os
import chromium_15612_release_evidence as source
import chromium_15612_variant as variant


def names(project: Path, lock: dict | None = None) -> list[str]:
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
    prefix = variant.reviewed_lock_prefix(lock) if lock is not None else source.PREFIX
    if prefix in variant.SUCCESSOR_PREFIXES:
        import chromium_15612_font_release_evidence as font
        result += [font.PREFIX + '-' + suffix + '.json' for suffix in (
            'source-contract', 'source-input-manifest', 'source-snapshot', 'port-candidate', 'source-proof')]
        policy = root / 'font-policy-v1'
        for name in font.MANIFESTS:
            manifest = source.read_object(policy / name, 'font source manifest')
            result += ['font-policy-v1/' + name, 'font-policy-v1/' + manifest['patchFile']]
            result += ['font-policy-v1/' + asset['source'] for asset in manifest.get('fixedAssets', [])]
            for owned, digest in manifest.get('ownedInputs', {}).items():
                path = source.safe_relative_regular(policy, owned)
                source.need(source.sha256_file(path) == digest, 'Owned font implementation drift')
                result.append('font-policy-v1/' + owned)
        result += ['font-policy-v1/native-probe/BUILD.gn', 'font-policy-v1/native-probe/neantik_font_probe.mm',
                   'font-policy-v1/headed-development.json']
        from chromium_15612_font_packaging import manifest, MANIFEST
        manifest(project)
        result.append(MANIFEST)
    if prefix in (variant.SECURITY_PREFIX, variant.COMPONENT_PREFIX):
        import chromium_15612_security_release_evidence as security
        # Authenticate the complete overlay before deriving any copy names.
        security.verify_contract(project)
        result += [security.PREFIX + '-' + suffix + '.json' for suffix in (
            'source-contract', 'source-input-manifest', 'source-snapshot', 'port-candidate', 'source-proof')]
        relative = 'security-backports-20261015/'
        manifest = source.read_object(root / relative / 'manifest.json', 'security source manifest')
        result.append(relative + 'manifest.json')
        result += [item['path'].removeprefix('runtime/') for item in manifest['orderedPatches']]
        result += [relative + name for name in manifest['licenseFiles']]
    if prefix == variant.COMPONENT_PREFIX:
        import chromium_15612_component_release_evidence as component
        component.verify_contract(project)
        result += [component.PREFIX + '-' + suffix + '.json' for suffix in (
            'source-contract', 'source-input-manifest', 'source-snapshot', 'port-candidate', 'source-proof')]
        for name in component.MANIFESTS:
            manifest = source.read_object(project / name, 'component source manifest')
            result += [name.removeprefix('runtime/'),
                       str(Path(name).parent / manifest['patchFile']).removeprefix('runtime/')]
        result += ['component-updates-v1/LICENSE', 'component-updates-v1/development-observation.json']
    source.need(len(result) == len(set(result)), 'Duplicate M156 packaged dependency')
    return result


def process(project: Path, evidence: Path, lock: dict, *, copy: bool = False) -> None:
    prefix = variant.reviewed_lock_prefix(lock)
    candidate = source.read_object(project / 'runtime' / (prefix + '-port-candidate.json'), 'M156 candidate')
    variant.verify_candidate_lock(lock, provenance=candidate, project_root=project)
    if evidence.is_symlink() or not evidence.is_dir():
        raise ValueError('Evidence root must be an existing regular directory')
    dependencies = names(project, lock)
    for relative in dependencies:
        # This single, public dependency lives outside runtime. Never copy the
        # private headed trace or broaden this mapping to a research directory.
        public_documents = {
            'font-policy-v1/headed-development.json': 'docs/evidence/font-variation-headed-development.json',
            'component-updates-v1/development-observation.json': 'docs/evidence/component-completion-development.json',
        }
        src = (source.safe_relative_regular(project, public_documents[relative])
               if relative in public_documents else source.safe_relative_regular(project / 'runtime', relative))
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
    subtrees = (('font-policy-v1', 'security-backports-20261015', 'component-updates-v1')
                if prefix == variant.COMPONENT_PREFIX else
                ('font-policy-v1', 'security-backports-20261015') if prefix == variant.SECURITY_PREFIX
                else ('font-policy-v1',) if prefix == variant.FONT_PREFIX else ())
    for subtree in subtrees:
        expected = {name for name in dependencies if name.startswith(subtree + '/')}
        expected_directories = {p.as_posix() for name in expected for p in Path(name).parents if p != Path('.')}
        for path in (evidence / subtree).rglob('*'):
            relative = path.relative_to(evidence).as_posix()
            if path.is_symlink() or not ((path.is_file() and relative in expected) or
                                         (path.is_dir() and relative in expected_directories)):
                raise ValueError('Packaged ' + subtree + ' evidence has an extra, linked or special member')


def normalize_font_modes(project: Path, evidence: Path, lock: dict) -> None:
    """Normalize only a closed, fresh unsigned evidence tree before sealing.

    Verification paths never change modes. Extra members, links and shared
    files are refused before touching any entry.
    """
    source.need(variant.reviewed_lock_prefix(lock) in variant.SUCCESSOR_PREFIXES,
                'Mode recipe needs an explicit font successor')
    process(project, evidence, lock)
    common = {'fingerprint-chromium.lock.json', 'source-provenance.json', 'args.gn',
              'runtime-verification.json', 'security-baseline.json', 'release-security-baseline.json',
              'neantik-patch-series.json', 'apple-device-tuples.json'}
    expected = set(names(project, lock)) | common
    directories = {p.as_posix() for name in expected for p in Path(name).parents if p != Path('.')}
    entries = list(evidence.rglob('*'))
    source.need(len(entries) <= 2_000 and not evidence.is_symlink() and evidence.is_dir(), 'Evidence mode namespace exceeds policy')
    seen = set()
    for path in entries:
        relative = path.relative_to(evidence).as_posix()
        source.need(not path.is_symlink() and path.stat().st_uid == os.getuid(), 'Unsafe evidence mode entry')
        if path.is_file():
            source.need(relative in expected and path.stat().st_nlink == 1, 'Unexpected or shared evidence file')
            seen.add(relative)
        else:
            source.need(path.is_dir() and relative in directories, 'Unexpected evidence directory')
    source.need(seen == expected, 'Missing evidence mode input')
    evidence.chmod(0o755)
    for path in entries:
        relative = path.relative_to(evidence).as_posix()
        path.chmod(0o755 if path.is_dir() else
                   0o600 if relative in {'runtime-verification.json', 'release-security-baseline.json'} else 0o644)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('lock', type=Path)
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--copy', action='store_true')
    parser.add_argument('--normalize-font-modes', action='store_true', help='Fresh unsigned font evidence only')
    args = parser.parse_args()
    try:
        project = Path(__file__).resolve().parents[1]
        lock = source.read_object(args.lock, 'M156 lock')
        if args.normalize_font_modes:
            if args.copy:
                parser.error('Copy and mode sealing are separate stages')
            normalize_font_modes(project, args.evidence, lock)
        else:
            process(project, args.evidence, lock, copy=args.copy)
    except (OSError, ValueError) as error:
        parser.exit(1, 'M156 packaged evidence rejected: ' + str(error) + '\n')
