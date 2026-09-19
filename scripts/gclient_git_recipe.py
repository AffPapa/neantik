"""Composite Git-only recipe verification for gclient source trees.

The recipe must be independently reviewed. This does not verify ignored GCS/
CIPD payloads, compiler outputs or binary provenance and cannot authorize release.
"""
from pathlib import Path

from gclient_source_evidence import (
    EvidenceError, parse_git_dependencies, verify_dependency_checkouts,
    verify_git_identity, verify_nonignored_untracked, verify_tracked_patch,
)


def exact_object(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise EvidenceError('Unexpected ' + label + ' fields')
    return value


def verify_git_recipe(source_root: Path, recipe: dict) -> dict:
    """Verify exact root/dependency Git identities, diffs and nonignored extras."""
    source_root = Path(source_root)
    exact_object(recipe, {'schemaVersion', 'scope', 'root', 'dependencies'}, 'Git recipe')
    if type(recipe['schemaVersion']) is not int or recipe['schemaVersion'] != 1 or recipe['scope'] != 'gclient-git-only':
        raise EvidenceError('Unsupported Git recipe schema or scope')
    root = exact_object(recipe['root'], {'commit', 'tree', 'trackedPatchSHA256',
                                        'untrackedFiles', 'untrackedLinks'}, 'root recipe')
    identity = verify_git_identity(source_root, commit=root['commit'], tree=root['tree'])
    if source_root.name != 'src':
        raise EvidenceError('gclient source root must be named src')
    entries = source_root.parent / '.gclient_entries'
    if entries.is_symlink() or not entries.is_file():
        raise EvidenceError('Missing regular gclient inventory')
    declared = parse_git_dependencies(entries.read_text(encoding='utf-8'))
    dependencies = recipe['dependencies']
    if not isinstance(dependencies, dict) or set(dependencies) != set(declared):
        raise EvidenceError('Git dependency coverage differs from gclient inventory')
    pins, patches = {}, {}
    for name, record in dependencies.items():
        exact_object(record, {'commit', 'trackedPatchSHA256', 'untrackedFiles', 'untrackedLinks'}, 'dependency recipe')
        if record['commit'] != declared[name]:
            raise EvidenceError('Git dependency declaration differs: ' + name)
        pins[name], patches[name] = record['commit'], record['trackedPatchSHA256']
    root_patch = verify_tracked_patch(source_root, root['trackedPatchSHA256'])
    root_extras = verify_nonignored_untracked(source_root, root['untrackedFiles'], root['untrackedLinks'])
    observed = verify_dependency_checkouts(source_root, pins, patches)
    for name, record in dependencies.items():
        observed[name]['nonignoredExtras'] = verify_nonignored_untracked(
            source_root / name, record['untrackedFiles'], record['untrackedLinks'])
    return {'scope': 'gclient-git-only', 'root': {**identity,
            'trackedPatchSHA256': root_patch, 'nonignoredExtras': root_extras},
            'dependencies': observed}
