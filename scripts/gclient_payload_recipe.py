"""Exact reviewed package-tree verification; not binary/release attestation."""
import os
from pathlib import Path, PurePosixPath

from gclient_source_evidence import EvidenceError, verify_files


def safe_relative(value):
    if not isinstance(value, str) or '\\' in value or PurePosixPath(value).is_absolute() or any(
        part in ('', '.', '..') for part in value.split('/')
    ):
        raise EvidenceError('Unsafe payload path')
    return value


def verify_payload_recipe(base: Path, recipe: dict) -> dict:
    """Compare full selected trees to reviewed regular files and contained links.

    Callers must independently validate the package declarations and expected
    maps. No generated-file wildcard or unknown-extra exemption is permitted.
    """
    base = Path(base)
    if not base.is_absolute() or base.is_symlink() or not base.is_dir():
        raise EvidenceError('Absolute nonsymlink payload base required')
    required = {'schemaVersion', 'scope', 'roots', 'files', 'links'}
    if not isinstance(recipe, dict) or not required <= set(recipe) or set(recipe) - required - {'missingLinkTargets'}:
        raise EvidenceError('Unexpected payload recipe fields')
    if type(recipe['schemaVersion']) is not int or recipe['schemaVersion'] != 1 or recipe['scope'] != 'gclient-payload-trees-only':
        raise EvidenceError('Unsupported payload recipe')
    roots, files, links = recipe['roots'], recipe['files'], recipe['links']
    missing_targets = recipe.get('missingLinkTargets', {})
    if not isinstance(missing_targets, dict) or not isinstance(links, dict) or set(missing_targets) - set(links):
        raise EvidenceError('Invalid explicitly absent link targets')
    if not isinstance(roots, list) or not roots or not isinstance(files, dict) or not isinstance(links, dict):
        raise EvidenceError('Invalid payload inventory')
    roots = [safe_relative(root) for root in roots]
    if len(set(roots)) != len(roots) or any(a != b and a.startswith(b + '/') for a in roots for b in roots):
        raise EvidenceError('Duplicate or overlapping payload roots')
    if set(files) & set(links):
        raise EvidenceError('Conflicting payload types')
    expected = set(files) | set(links)
    for name in expected:
        safe_relative(name)
        if not any(name.startswith(root + '/') for root in roots):
            raise EvidenceError('Payload entry outside selected roots')
    observed = set()
    def walk_error(error):
        raise EvidenceError('Cannot enumerate payload tree') from error
    for root in roots:
        directory = base
        for part in root.split('/'):
            directory /= part
            if directory.is_symlink() or not directory.is_dir():
                raise EvidenceError('Unsafe or missing payload root')
        for parent, directories, names in os.walk(directory, followlinks=False, onerror=walk_error):
            for name in list(directories):
                path = Path(parent) / name
                if path.is_symlink():
                    observed.add(path.relative_to(base).as_posix())
                    directories.remove(name)
            observed.update((Path(parent) / name).relative_to(base).as_posix() for name in names)
    if observed != expected:
        raise EvidenceError('Payload tree contains missing or unexpected entries')
    verified = verify_files(base, files) if files else {}
    for name, target in links.items():
        path = base / name
        if not isinstance(target, str) or not target or PurePosixPath(target).is_absolute() or not path.is_symlink() or str(path.readlink()) != target:
            raise EvidenceError('Unexpected payload link')
        try:
            resolved = path.resolve(strict=name not in missing_targets)
            relative = resolved.relative_to(base.resolve()).as_posix()
        except (OSError, ValueError, RuntimeError) as error:
            raise EvidenceError('Payload link escapes or is unresolved') from error
        if name in missing_targets:
            # Some official cross-platform toolchains contain inert aliases
            # for platforms absent from that archive. Require exact absence;
            # this is not a wildcard permission for dangling links.
            safe_relative(missing_targets[name])
            if relative != missing_targets[name] or resolved.exists() or resolved.is_symlink():
                raise EvidenceError('Expected absent target changed')
            continue
        # Every destination must itself be covered, not merely exist nearby.
        if relative not in files and not (resolved.is_dir() and any(n.startswith(relative + '/') for n in files)):
            raise EvidenceError('Payload link destination is not verified')
    return {'scope': recipe['scope'], 'roots': roots, 'files': verified,
            'links': dict(links), 'missingLinkTargets': dict(missing_targets)}
