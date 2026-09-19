"""Strict building block for gclient evidence, not a release attestation.

Callers must separately supply reviewed dependency/toolchain and patch coverage.
This module never accepts a baseline learned from the same source being checked.
"""
import hashlib
import ast
from pathlib import Path, PurePosixPath
import re
import subprocess


class EvidenceError(ValueError):
    pass


def parse_git_dependencies(text: str) -> dict[str, str]:
    """Read gclient's inventory as data, never execute its Python syntax.

    Non-Git entries require separate CIPD/GCS verification; this is not a
    complete dependency attestation and does not assert checkout cleanliness.
    """
    try:
        module = ast.parse(text)
        if len(module.body) != 1 or not isinstance(module.body[0], ast.Assign):
            raise ValueError()
        assignment = module.body[0]
        if len(assignment.targets) != 1 or not isinstance(assignment.targets[0], ast.Name) or assignment.targets[0].id != 'entries':
            raise ValueError()
        entries = ast.literal_eval(assignment.value)
        if not isinstance(entries, dict):
            raise ValueError()
    except (SyntaxError, ValueError, TypeError) as error:
        raise EvidenceError('Invalid gclient inventory') from error
    result = {}
    for name, url in entries.items():
        if not isinstance(name, str) or not isinstance(url, str):
            raise EvidenceError('Invalid inventory entry')
        # Git remotes need not end in .git (for example openscreen). CIPD
        # inventory keys include a package suffix separated by a colon.
        git_candidate = '.git@' in url or (
            name != 'src' and ':' not in name and url.startswith(('https://', 'http://'))
        )
        if not git_candidate:
            continue
        if not name.startswith('src/') or any(p in ('', '.', '..') for p in name.split('/')) or '\\' in name:
            raise EvidenceError('Unsafe dependency path')
        revision = url.rsplit('@', 1)[-1]
        if not re.fullmatch('[0-9a-f]{40}', revision):
            raise EvidenceError('Unpinned Git dependency')
        result[name[4:]] = revision
    if not result:
        raise EvidenceError('No pinned Git dependencies')
    return dict(sorted(result.items()))


def checked_file(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or '\\' in relative:
        raise EvidenceError('Invalid source path')
    parts = PurePosixPath(relative)
    if parts.is_absolute() or not relative or any(p in ('', '.', '..') for p in relative.split('/')):
        raise EvidenceError('Unsafe source path')
    current = root
    for component in parts.parts:
        current = current / component
        if current.is_symlink():
            raise EvidenceError('Symlink in source path')
    if not current.is_file():
        raise EvidenceError('Missing regular source file')
    return current


def verify_files(root: Path, expected: dict[str, str]) -> dict[str, str]:
    root = Path(root)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise EvidenceError('Absolute non-symlink source directory required')
    if not isinstance(expected, dict) or not expected:
        raise EvidenceError('Reviewed file hashes required')
    observed = {}
    for relative, expected_hash in sorted(expected.items()):
        if not isinstance(expected_hash, str) or not re.fullmatch('[0-9a-f]{64}', expected_hash):
            raise EvidenceError('Invalid expected hash')
        path = checked_file(root, relative)
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        actual = digest.hexdigest()
        if actual != expected_hash:
            raise EvidenceError('Source file hash mismatch: ' + relative)
        observed[relative] = actual
    return observed


def verify_git_identity(root: Path, *, commit: str, tree: str) -> dict[str, str]:
    root = Path(root)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise EvidenceError('Absolute non-symlink source directory required')
    for value in (commit, tree):
        if not re.fullmatch('[0-9a-f]{40}', value):
            raise EvidenceError('Invalid expected Git identity')
    def git(*args):
        result = subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True)
        if result.returncode:
            raise EvidenceError('Cannot inspect source Git identity')
        return result.stdout.strip()
    if Path(git('rev-parse', '--show-toplevel')).resolve() != root.resolve():
        raise EvidenceError('Source must be the exact repository root')
    if git('rev-parse', 'HEAD') != commit or git('rev-parse', 'HEAD^{tree}') != tree:
        raise EvidenceError('Source Git identity mismatch')
    return {'commit': commit, 'tree': tree}


def verify_tracked_patch(root: Path, expected_sha256: str) -> str:
    """Check all tracked changes against a separately reviewed binary diff.

    Includes staged changes; excludes untracked/ignored files, which require
    separate coverage. Must be paired with verify_git_identity.
    """
    if not isinstance(expected_sha256, str) or not re.fullmatch('[0-9a-f]{64}', expected_sha256):
        raise EvidenceError('Reviewed patch SHA-256 required')
    result = subprocess.run(
        ['git', '-C', str(root), '-c', 'core.autocrlf=false', 'diff',
         '--no-ext-diff', '--no-textconv', '--binary', '--full-index',
         '--no-renames', '--src-prefix=a/', '--dst-prefix=b/', 'HEAD', '--'],
        capture_output=True,
    )
    if result.returncode:
        raise EvidenceError('Cannot inspect tracked source patch')
    digest = hashlib.sha256(result.stdout).hexdigest()
    if digest != expected_sha256:
        raise EvidenceError('Tracked source patch differs from reviewed patch')
    return digest


def verify_dependency_checkouts(root: Path, revisions: dict[str, str],
                                reviewed_patches: dict[str, str]) -> dict:
    """Verify reviewed Git pins and tracked patches, not CIPD or untracked files.

    Pins must come from independently reviewed dependency inputs, not be learned
    from HEAD by the caller. Unlisted dependencies must have no tracked changes.
    """
    if not revisions or set(reviewed_patches) - set(revisions):
        raise EvidenceError('Invalid dependency patch coverage')
    root = Path(root)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise EvidenceError('Absolute non-symlink source directory required')
    observed = {}
    for relative, revision in sorted(revisions.items()):
        if not relative or '\\' in relative or PurePosixPath(relative).is_absolute() or any(
            part in ('', '.', '..') for part in relative.split('/')
        ):
            raise EvidenceError('Unsafe dependency path')
        directory = root
        for part in relative.split('/'):
            directory = directory / part
            if directory.is_symlink() or not directory.is_dir():
                raise EvidenceError('Unsafe dependency directory')
        if not isinstance(revision, str) or not re.fullmatch('[0-9a-f]{40}', revision):
            raise EvidenceError('Invalid dependency revision')
        result = subprocess.run(['git', '-C', str(directory), 'rev-parse', '--show-toplevel', 'HEAD'],
                                capture_output=True, text=True)
        lines = result.stdout.splitlines()
        if result.returncode or len(lines) != 2 or Path(lines[0]).resolve() != directory.resolve() or lines[1] != revision:
            raise EvidenceError('Dependency identity mismatch: ' + relative)
        try:
            patch = verify_tracked_patch(directory, reviewed_patches.get(relative, hashlib.sha256(b'').hexdigest()))
        except EvidenceError as error:
            raise EvidenceError('Dependency patch mismatch: ' + relative) from error
        observed[relative] = {'commit': revision, 'trackedPatchSHA256': patch}
    return observed


def verify_nonignored_untracked(root: Path, files: dict[str, str],
                               links: dict[str, dict[str, str]]) -> dict:
    """Require exact nonignored untracked coverage, including reviewed links.

    Not a check of ignored files or nested repositories. Callers must cover
    those separately; no absence-of-extra-input claim follows from this alone.
    Expected hashes/targets must come from independently reviewed recipes.
    """
    root = Path(root)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise EvidenceError('Absolute non-symlink source directory required')
    if not isinstance(files, dict) or not isinstance(links, dict) or set(files) & set(links):
        raise EvidenceError('Invalid untracked coverage')
    result = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                            capture_output=True, text=True)
    if result.returncode or Path(result.stdout.strip()).resolve() != root.resolve():
        raise EvidenceError('Exact repository root required')
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '--others',
                             '--exclude-standard', '-z'], capture_output=True)
    if result.returncode:
        raise EvidenceError('Cannot list untracked source')
    try:
        actual = set(filter(None, result.stdout.decode('utf-8').split('\0')))
    except UnicodeDecodeError as error:
        raise EvidenceError('Unsupported untracked filename') from error
    if actual != set(files) | set(links):
        raise EvidenceError('Untracked source inventory differs from reviewed recipe')
    verified = verify_files(root, files) if files else {}
    for name, expected in sorted(links.items()):
        if not isinstance(name, str) or '\\' in name or PurePosixPath(name).is_absolute() or any(
            part in ('', '.', '..') for part in name.split('/')
        ):
            raise EvidenceError('Unsafe symlink source path')
        if not isinstance(expected, dict) or set(expected) != {'target', 'sha256'}:
            raise EvidenceError('Invalid symlink evidence')
        path = root
        for part in name.split('/')[:-1]:
            path /= part
            if path.is_symlink() or not path.is_dir():
                raise EvidenceError('Unsafe symlink parent')
        path /= name.split('/')[-1]
        target = expected['target']
        if not isinstance(target, str) or PurePosixPath(target).is_absolute() or not path.is_symlink() or str(path.readlink()) != target:
            raise EvidenceError('Symlink target mismatch')
        try:
            resolved = path.resolve(strict=True)
            relative = resolved.relative_to(root.resolve()).as_posix()
        except (OSError, ValueError, RuntimeError) as error:
            raise EvidenceError('Symlink escapes source or is unresolved') from error
        verify_files(root, {relative: expected['sha256']})
        verified[name] = dict(expected)
    return verified
