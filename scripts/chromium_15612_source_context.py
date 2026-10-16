"""Process-local source expectations, never a cached artifact qualification.

Only a complete clean Git-root snapshot is eligible. The existing release
snapshot checks every tracked byte, file identity and parent directory; each
operation rechecks it. No context is loaded from JSON or written to disk.
"""
from contextlib import contextmanager
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import sys

from release_source_receipt import (capture_release_source, assert_release_source_unchanged,
                                    ReleaseSourceReceiptError, _run_git)

_TOKEN = object()


class SourceContextUnavailable(ValueError):
    """No reusable context; the original full development check remains valid."""


def _require_verifier_project(project):
    scripts = Path(__file__).resolve().parent
    if Path(project).resolve() != scripts.parent:
        raise SourceContextUnavailable("Source context must seal the running verifier's project")
    # Include every own importable helper, not just the M156-named modules.
    # The source snapshot separately seals this directory's full membership.
    owned_names = {path.stem for path in scripts.glob('*.py')}
    for name, module in tuple(sys.modules.items()):
        if name in owned_names:
            path = getattr(module, '__file__', None)
            if path is None or Path(path).resolve() != scripts / (name + '.py'):
                raise ValueError("Source context verifier module binding changed")


def _encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def _execution_identity():
    executable = Path(sys.executable).resolve(strict=True)
    with executable.open("rb") as stream:
        binary = hashlib.file_digest(stream, "sha256").digest()
    # Environment values remain in memory and are never placed in a receipt,
    # repr or error. A changed import path also invalidates reuse.
    return (str(executable), binary, sys.version, sys.implementation.cache_tag, os.getcwd(),
            tuple(sys.path), hashlib.sha256(_encoded(dict(os.environ))).digest())


def _assert_source(snapshot):
    try:
        assert_release_source_unchanged(snapshot)
    except ReleaseSourceReceiptError as error:
        raise ValueError("Source context inputs changed") from error


@dataclass(frozen=True, repr=False)
class VerifiedSourceContext:
    _snapshot: object = field(repr=False)
    _lock: bytes = field(repr=False)
    _fields: bytes = field(repr=False)
    _dependencies: tuple[str, ...] = field(repr=False)
    _execution: tuple = field(repr=False)
    _token: object = field(repr=False)
    _failed: bool = field(default=False, init=False, repr=False)

    def __post_init__(self):
        if self._token is not _TOKEN:
            raise ValueError("Source context requires completed in-process validation")

    def __repr__(self):
        return "<VerifiedSourceContext invalid>" if self._failed else "<VerifiedSourceContext process-local>"

    @property
    def dependencies(self):
        return self._dependencies

    def source_fields(self):
        return json.loads(self._fields)

    def _assert_current(self, project, lock):
        if self._failed or self._token is not _TOKEN:
            raise ValueError("Source context is invalid")
        _require_verifier_project(project)
        if (Path(project).resolve() != self._snapshot.project_root
                or _encoded(lock) != self._lock
                or _execution_identity() != self._execution):
            raise ValueError("Source context identity changed")
        _assert_source(self._snapshot)

    @contextmanager
    def operation(self, project, lock):
        """No stale success survives an input change or a failed operation."""
        try:
            self._assert_current(project, lock)
            yield self
            self._assert_current(project, lock)
        except BaseException:
            object.__setattr__(self, "_failed", True)
            raise


def verify_source_context(project: Path, lock: dict) -> VerifiedSourceContext:
    """Run full semantics once, then seal their source-only expectations.

    Dirty/nested trees are refused here. Callers needing a development-only
    check may keep the original full-verification path without a context.
    """
    from chromium_15612_packaged_evidence import _verified_source_expectations

    _require_verifier_project(project)
    execution = _execution_identity()
    pinned_lock = _encoded(lock)
    try:
        top = _run_git(Path(project), ['rev-parse', '--show-toplevel']).decode().strip()
    except ReleaseSourceReceiptError as error:
        raise SourceContextUnavailable("Standalone source has no complete Git snapshot") from error
    if Path(top).resolve() != Path(project).resolve():
        raise SourceContextUnavailable("Nested development source has no complete Git snapshot")
    if _run_git(Path(project), ['status', '--porcelain=v1', '--untracked-files=all', '--ignored=no']):
        raise SourceContextUnavailable("Dirty development source requires full verification")
    # Empty role annotations still seal ALL tracked bytes and directories.
    try:
        snapshot = capture_release_source(Path(project), closure=())
    except ReleaseSourceReceiptError as error:
        # Clean preflight was already established. A failure now is drift or
        # an unsafe snapshot, not permission to continue with foreign inputs.
        raise ValueError("Source context snapshot failed after clean preflight") from error
    if snapshot.payload["git"]["worktreeState"] != "clean":
        raise ValueError("Source context needs a complete clean Git root")
    fields, dependencies = _verified_source_expectations(snapshot.project_root, json.loads(pinned_lock))
    _require_verifier_project(project)
    tracked = {item.relative_path for item in snapshot.files}
    public = {
        "font-policy-v1/headed-development.json": "docs/evidence/font-variation-headed-development.json",
        "component-updates-v1/development-observation.json": "docs/evidence/component-completion-development.json",
    }
    required = {public.get(name, "runtime/" + name) for name in dependencies}
    required.add("scripts/chromium_15612_source_context.py")
    if not required <= tracked:
        raise ValueError("Source context dependencies must be in the complete tracked snapshot")
    if execution != _execution_identity() or pinned_lock != _encoded(lock):
        raise ValueError("Source context execution changed during validation")
    _assert_source(snapshot)
    return VerifiedSourceContext(snapshot, pinned_lock, _encoded(fields),
                                 tuple(dependencies), execution, _TOKEN)
