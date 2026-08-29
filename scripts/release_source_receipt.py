#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


class ReleaseSourceReceiptError(RuntimeError):
    pass


@dataclass(frozen=True)
class SourceFileSeal:
    path: Path
    relative_path: str
    sha256: str
    size: int
    device: int
    inode: int
    mtime_ns: int
    ctime_ns: int


@dataclass(frozen=True)
class SourceDirectorySeal:
    path: Path
    device: int
    inode: int
    mtime_ns: int
    ctime_ns: int


@dataclass(frozen=True)
class ReleaseSourceSnapshot:
    project_root: Path
    payload: dict[str, object]
    files: tuple[SourceFileSeal, ...]
    directories: tuple[SourceDirectorySeal, ...] = ()


RELEASE_SOURCE_CLOSURE: tuple[tuple[str, str], ...] = (
    ("runtime/apple-device-tuples.json", "reviewed-policy"),
    ("runtime/browser-identity-issuance.json", "reviewed-policy"),
    ("runtime/chromium-152-source-contract.json", "reviewed-policy"),
    ("runtime/chromium-152-toolchain-lock.json", "reviewed-toolchain-lock"),
    ("runtime/nevision-patches/series.json", "reviewed-policy"),
    ("runtime/security-baseline.json", "reviewed-policy"),
    ("scripts/direct-candidate-manifest.py", "candidate-manifest"),
    ("scripts/fingerprint_evidence_schema8.py", "evidence-schema"),
    ("scripts/notarize-direct-candidate.sh", "release-entrypoint"),
    ("scripts/notarize_direct_transaction.py", "orchestrator"),
    ("scripts/notary_transaction_inspector.py", "transaction-diagnostics"),
    ("scripts/notary_transaction_state.py", "transaction-state"),
    ("scripts/release-direct.sh", "release-entrypoint"),
    ("scripts/release_input_snapshot.py", "input-snapshot"),
    ("scripts/release_source_receipt.py", "source-provenance"),
    ("scripts/release_transaction.py", "transaction"),
    ("scripts/run-isolated-release-python.py", "execution-bootstrap"),
    ("scripts/verify-browser-identity-issuance.py", "fingerprint-gate"),
    ("scripts/verify-direct-notarized-archive.py", "release-gate"),
    ("scripts/verify-direct-telemetry-disabled.py", "privacy-gate"),
    ("scripts/verify-direct-update-policy.py", "release-gate"),
    ("scripts/verify-direct-version-bump.py", "release-gate"),
    ("scripts/verify-fingerprint-evidence-envelope.py", "evidence-gate"),
    ("scripts/verify-gui-fingerprint-report.py", "evidence-gate"),
    ("scripts/verify-integrated-release.sh", "release-gate"),
    ("scripts/verify-public-artifact-privacy.py", "privacy-gate"),
    ("scripts/verify-public-fingerprint-corpus.py", "fingerprint-gate"),
    ("scripts/verify-runtime-security-baseline.py", "security-gate"),
    ("scripts/verify-runtime-security-reference.py", "security-gate"),
)

_MAXIMUM_SOURCE_FILE_BYTES = 32 * 1024 * 1024
_MAXIMUM_TOTAL_SOURCE_BYTES = 256 * 1024 * 1024
_MAXIMUM_BATCH_BLOB_BYTES = 256 * 1024 * 1024
_MAXIMUM_TRACKED_FILES = 10_000
_MAXIMUM_TRACKED_PATH_BYTES = 4 * 1024 * 1024
_MAXIMUM_GIT_QUERY_BYTES = 2 * 1024 * 1024
_MAXIMUM_GIT_OUTPUT_BYTES = 16 * 1024 * 1024


def _git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for key in tuple(environment):
        if key.startswith("GIT_"):
            environment.pop(key)
    environment.update(
        {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
        }
    )
    return environment


def _run_git(
    project_root: Path,
    arguments: list[str],
    *,
    maximum_output_bytes: int = _MAXIMUM_GIT_OUTPUT_BYTES,
) -> bytes:
    try:
        with (
            tempfile.TemporaryFile() as output,
            tempfile.TemporaryFile() as errors,
        ):
            completed = subprocess.run(
                [
                    "/usr/bin/git",
                    "--no-replace-objects",
                    "-C",
                    str(project_root),
                    *arguments,
                ],
                stdout=output,
                stderr=errors,
                check=False,
                timeout=30,
                env=_git_environment(),
            )
            output_size = output.tell()
            error_size = errors.tell()
            if (
                output_size > maximum_output_bytes
                or error_size > _MAXIMUM_GIT_OUTPUT_BYTES
            ):
                raise ReleaseSourceReceiptError(
                    "release source Git query output is too large"
                )
            output.seek(0)
            result = output.read(maximum_output_bytes + 1)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseSourceReceiptError(
            "release source Git query failed"
        ) from error
    if completed.returncode != 0:
        raise ReleaseSourceReceiptError(
            "release source Git query failed"
        )
    if len(result) != output_size:
        raise ReleaseSourceReceiptError(
            "release source Git query output is invalid"
        )
    return result


def _read_committed_blobs(
    project_root: Path,
    objects: tuple[tuple[str, int], ...],
    *,
    identifier_length: int,
) -> tuple[bytes, ...]:
    if not objects:
        raise ReleaseSourceReceiptError(
            "release source tracked-file inventory is invalid"
        )
    if len(objects) > _MAXIMUM_TRACKED_FILES:
        raise ReleaseSourceReceiptError(
            "release source contains too many tracked files"
        )
    unique_objects: dict[str, int] = {}
    for identifier, expected_size in objects:
        if (
            len(identifier) != identifier_length
            or any(
                character not in "0123456789abcdef"
                for character in identifier
            )
            or expected_size < 0
            or expected_size > _MAXIMUM_SOURCE_FILE_BYTES
        ):
            raise ReleaseSourceReceiptError(
                "release source Git blob identifier is invalid"
            )
        known_size = unique_objects.setdefault(identifier, expected_size)
        if known_size != expected_size:
            raise ReleaseSourceReceiptError(
                "release source Git blob inventory is inconsistent"
            )
    total_size = sum(unique_objects.values())
    if total_size > _MAXIMUM_BATCH_BLOB_BYTES:
        raise ReleaseSourceReceiptError(
            "release source Git blobs exceed the batch memory limit"
        )
    request = b"".join(
        identifier.encode("ascii") + b"\0"
        for identifier in unique_objects
    )
    if len(request) > _MAXIMUM_GIT_QUERY_BYTES:
        raise ReleaseSourceReceiptError(
            "release source Git blob request is too large"
        )
    try:
        completed = subprocess.run(
            [
                "/usr/bin/git",
                "--no-replace-objects",
                "-C",
                str(project_root),
                "cat-file",
                "--batch",
                "-Z",
            ],
            input=request,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=60,
            env=_git_environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseSourceReceiptError(
            "release source Git blob query failed"
        ) from error
    if completed.returncode != 0:
        raise ReleaseSourceReceiptError(
            "release source Git blob query failed"
        )
    output = completed.stdout
    maximum_response_size = total_size + (
        len(unique_objects) * (identifier_length + 64)
    )
    if len(output) > maximum_response_size:
        raise ReleaseSourceReceiptError(
            "release source Git blob response is invalid"
        )
    cursor = 0
    blobs: dict[str, bytes] = {}
    for expected_identifier, expected_size in unique_objects.items():
        header_end = output.find(b"\0", cursor)
        if header_end < 0:
            raise ReleaseSourceReceiptError(
                "release source Git blob response is invalid"
            )
        header = output[cursor:header_end].split(b" ")
        if len(header) != 3:
            raise ReleaseSourceReceiptError(
                "release source Git blob response is invalid"
            )
        try:
            observed_identifier = header[0].decode(
                "ascii",
                errors="strict",
            )
            object_type = header[1].decode("ascii", errors="strict")
            size_text = header[2].decode("ascii", errors="strict")
            size = int(size_text, 10)
        except (UnicodeDecodeError, ValueError) as error:
            raise ReleaseSourceReceiptError(
                "release source Git blob response is invalid"
            ) from error
        if (
            observed_identifier != expected_identifier
            or object_type != "blob"
            or size != expected_size
            or str(size) != size_text
        ):
            raise ReleaseSourceReceiptError(
                "release source Git blob response is invalid"
            )
        start = header_end + 1
        end = start + size
        if end >= len(output) or output[end : end + 1] != b"\0":
            raise ReleaseSourceReceiptError(
                "release source Git blob response is invalid"
            )
        blobs[expected_identifier] = output[start:end]
        cursor = end + 1
    if cursor != len(output):
        raise ReleaseSourceReceiptError(
            "release source Git blob response is invalid"
        )
    return tuple(blobs[identifier] for identifier, _size in objects)


def _strict_git_identifier(value: bytes, *, length: int) -> str:
    text = value.decode("ascii", errors="strict").strip()
    if (
        len(text) != length
        or any(character not in "0123456789abcdef" for character in text)
    ):
        raise ReleaseSourceReceiptError(
            "release source Git identifier is invalid"
        )
    return text


def _read_source_file(
    project_root: Path,
    relative_path: str,
) -> tuple[bytes, os.stat_result]:
    parts = Path(relative_path).parts
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    file_flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
        file_flags |= os.O_NOFOLLOW
    directories: list[int] = []
    try:
        parent = os.open(project_root, directory_flags)
        directories.append(parent)
        for component in parts[:-1]:
            parent = os.open(
                component,
                directory_flags,
                dir_fd=parent,
            )
            directories.append(parent)
        descriptor = os.open(
            parts[-1],
            file_flags,
            dir_fd=parent,
        )
    except OSError as error:
        for opened in reversed(directories):
            os.close(opened)
        raise ReleaseSourceReceiptError(
            "release source tracked file is unavailable"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or before.st_size > _MAXIMUM_SOURCE_FILE_BYTES
        ):
            raise ReleaseSourceReceiptError(
                "release source tracked file is unsafe"
            )
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > _MAXIMUM_SOURCE_FILE_BYTES:
                raise ReleaseSourceReceiptError(
                    "release source tracked file is too large"
                )
            chunks.append(chunk)
        after = os.fstat(descriptor)
    except OSError as error:
        raise ReleaseSourceReceiptError(
            "release source tracked file could not be read"
        ) from error
    finally:
        os.close(descriptor)
        for opened in reversed(directories):
            os.close(opened)
    if (
        before.st_dev != after.st_dev
        or before.st_ino != after.st_ino
        or before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
        or total != after.st_size
    ):
        raise ReleaseSourceReceiptError(
            "release source tracked file changed while reading"
        )
    return b"".join(chunks), before


def _seal_source_directory(path: Path) -> SourceDirectorySeal:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        status = os.fstat(descriptor)
    except OSError as error:
        raise ReleaseSourceReceiptError(
            "release source directory is unavailable"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_uid != os.geteuid()
        or status.st_mode & 0o022
    ):
        raise ReleaseSourceReceiptError(
            "release source directory is unsafe"
        )
    return SourceDirectorySeal(
        path=path,
        device=status.st_dev,
        inode=status.st_ino,
        mtime_ns=status.st_mtime_ns,
        ctime_ns=status.st_ctime_ns,
    )


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def capture_release_source(
    project_root: Path,
    *,
    closure: tuple[tuple[str, str], ...] = RELEASE_SOURCE_CLOSURE,
) -> ReleaseSourceSnapshot:
    project_root = project_root.resolve()
    top_level = Path(
        _run_git(project_root, ["rev-parse", "--show-toplevel"])
        .decode("utf-8", errors="strict")
        .strip()
    ).resolve()
    if top_level != project_root:
        return _capture_nested_release_source(
            project_root,
            top_level=top_level,
            closure=closure,
        )
    status = _run_git(
        project_root,
        [
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignored=no",
        ],
    )
    if status:
        raise ReleaseSourceReceiptError(
            "release source worktree is not clean"
        )
    object_format = (
        _run_git(top_level, ["rev-parse", "--show-object-format"])
        .decode("ascii", errors="strict")
        .strip()
    )
    identifier_length = {"sha1": 40, "sha256": 64}.get(object_format)
    if identifier_length is None:
        raise ReleaseSourceReceiptError(
            "release source Git object format is unsupported"
        )
    commit = _strict_git_identifier(
        _run_git(project_root, ["rev-parse", "HEAD"]),
        length=identifier_length,
    )
    tree = _strict_git_identifier(
        _run_git(project_root, ["rev-parse", "HEAD^{tree}"]),
        length=identifier_length,
    )
    if (
        tuple(sorted(path for path, _role in closure))
        != tuple(path for path, _role in closure)
        or len({path for path, _role in closure}) != len(closure)
    ):
        raise ReleaseSourceReceiptError(
            "release source closure must be sorted and unique"
        )

    tracked_raw = _run_git(
        project_root,
        ["ls-tree", "-r", "-l", "-z", "--full-tree", tree],
        maximum_output_bytes=_MAXIMUM_GIT_OUTPUT_BYTES,
    )
    tracked_entries: list[tuple[str, str, int]] = []
    try:
        for item in tracked_raw.split(b"\0"):
            if not item:
                continue
            metadata, raw_path = item.split(b"\t", 1)
            (
                mode,
                object_type,
                raw_identifier,
                raw_size,
            ) = metadata.split()
            relative_path = raw_path.decode("utf-8", errors="strict")
            identifier = raw_identifier.decode("ascii", errors="strict")
            size_text = raw_size.decode("ascii", errors="strict")
            size = int(size_text, 10)
            if (
                object_type != b"blob"
                or mode not in {b"100644", b"100755"}
                or len(identifier) != identifier_length
                or any(
                    character not in "0123456789abcdef"
                    for character in identifier
                )
                or size < 0
                or size > _MAXIMUM_SOURCE_FILE_BYTES
                or str(size) != size_text
            ):
                raise ValueError("unsupported tracked object")
            tracked_entries.append((relative_path, identifier, size))
            if len(tracked_entries) > _MAXIMUM_TRACKED_FILES:
                raise ValueError("too many tracked files")
    except (UnicodeDecodeError, ValueError) as error:
        raise ReleaseSourceReceiptError(
            "release source tracked-file inventory is invalid"
        ) from error
    tracked_paths = tuple(
        path for path, _identifier, _size in tracked_entries
    )
    if (
        sum(len(path.encode("utf-8")) for path in tracked_paths)
        > _MAXIMUM_TRACKED_PATH_BYTES
    ):
        raise ReleaseSourceReceiptError(
            "release source tracked paths exceed the aggregate limit"
        )
    if (
        sum(size for _path, _identifier, size in tracked_entries)
        > _MAXIMUM_TOTAL_SOURCE_BYTES
    ):
        raise ReleaseSourceReceiptError(
            "release source tracked files exceed the aggregate limit"
        )
    if (
        tuple(sorted(tracked_paths)) != tracked_paths
        or len(set(tracked_paths)) != len(tracked_paths)
        or not tracked_paths
    ):
        raise ReleaseSourceReceiptError(
            "release source tracked-file inventory is invalid"
        )
    committed_contents = _read_committed_blobs(
        project_root,
        tuple(
            (identifier, size)
            for _path, identifier, size in tracked_entries
        ),
        identifier_length=identifier_length,
    )
    closure_roles = dict(closure)
    if not set(closure_roles).issubset(tracked_paths):
        raise ReleaseSourceReceiptError(
            "release source closure contains an untracked file"
        )
    python_parents = {
        (project_root / relative_path).parent
        for relative_path in tracked_paths
        if relative_path.endswith(".py")
    }
    for parent in python_parents:
        if (
            os.path.lexists(parent / "__pycache__")
            or any(parent.glob("*.pyc"))
        ):
            raise ReleaseSourceReceiptError(
                "release source contains executable Python bytecode cache"
            )

    entries: list[dict[str, object]] = []
    seals: list[SourceFileSeal] = []
    directory_paths: set[Path] = {project_root}
    for relative_path, committed in zip(
        tracked_paths,
        committed_contents,
        strict=True,
    ):
        if (
            not relative_path
            or relative_path.startswith("/")
            or ".." in Path(relative_path).parts
        ):
            raise ReleaseSourceReceiptError(
                "release source tracked path is invalid"
            )
        if (
            relative_path in closure_roles
            and not closure_roles[relative_path]
        ):
            raise ReleaseSourceReceiptError(
                "release source closure entry is invalid"
            )
        contents, file_status = _read_source_file(
            project_root,
            relative_path,
        )
        current_parent = (project_root / relative_path).parent
        while current_parent != project_root:
            directory_paths.add(current_parent)
            current_parent = current_parent.parent
        if committed != contents:
            raise ReleaseSourceReceiptError(
                "release source tracked file differs from HEAD"
            )
        digest = hashlib.sha256(contents).hexdigest()
        if relative_path in closure_roles:
            entries.append(
                {
                    "path": relative_path,
                    "role": closure_roles[relative_path],
                    "sha256": digest,
                    "size": len(contents),
                }
            )
        seals.append(
            SourceFileSeal(
                path=project_root / relative_path,
                relative_path=relative_path,
                sha256=digest,
                size=len(contents),
                device=file_status.st_dev,
                inode=file_status.st_ino,
                mtime_ns=file_status.st_mtime_ns,
                ctime_ns=file_status.st_ctime_ns,
            )
        )
    final_commit = _strict_git_identifier(
        _run_git(top_level, ["rev-parse", "HEAD"]),
        length=identifier_length,
    )
    final_tree = _strict_git_identifier(
        _run_git(top_level, ["rev-parse", "HEAD^{tree}"]),
        length=identifier_length,
    )
    final_status = _run_git(
        project_root,
        [
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignored=no",
        ],
    )
    if (
        final_commit != commit
        or final_tree != tree
        or final_status
    ):
        raise ReleaseSourceReceiptError(
            "release source changed while it was captured"
        )
    closure_digest = hashlib.sha256(_canonical_json(entries)).hexdigest()
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "project": "NeAntik",
        "repositoryClaim": "AffPapa/neantik",
        "git": {
            "objectFormat": object_format,
            "commit": commit,
            "tree": tree,
            "worktreeState": "clean",
        },
        "digestAlgorithm": "sha256",
        "closure": entries,
        "closureSHA256": closure_digest,
    }
    return ReleaseSourceSnapshot(
        project_root=project_root,
        payload=payload,
        files=tuple(seals),
        directories=tuple(
            _seal_source_directory(path)
            for path in sorted(directory_paths)
        ),
    )


def _capture_nested_release_source(
    project_root: Path,
    *,
    top_level: Path,
    closure: tuple[tuple[str, str], ...],
) -> ReleaseSourceSnapshot:
    try:
        relative_project_root = project_root.relative_to(top_level)
    except ValueError as error:
        raise ReleaseSourceReceiptError(
            "release source escapes detected Git worktree"
        ) from error
    if not relative_project_root.parts:
        raise ReleaseSourceReceiptError(
            "release source must be the exact Git worktree root"
        )
    object_format = (
        _run_git(top_level, ["rev-parse", "--show-object-format"])
        .decode("ascii", errors="strict")
        .strip()
    )
    identifier_length = {"sha1": 40, "sha256": 64}.get(object_format)
    if identifier_length is None:
        raise ReleaseSourceReceiptError(
            "release source Git object format is unsupported"
        )
    try:
        commit = _strict_git_identifier(
            _run_git(top_level, ["rev-parse", "HEAD"]),
            length=identifier_length,
        )
        tree = _strict_git_identifier(
            _run_git(top_level, ["rev-parse", "HEAD^{tree}"]),
            length=identifier_length,
        )
        worktree_state = "nested-source-closure-sealed"
    except ReleaseSourceReceiptError:
        commit = "unborn"
        tree = "unborn"
        worktree_state = "nested-source-closure-sealed-unborn-parent"
    if (
        tuple(sorted(path for path, _role in closure))
        != tuple(path for path, _role in closure)
        or len({path for path, _role in closure}) != len(closure)
    ):
        raise ReleaseSourceReceiptError(
            "release source closure must be sorted and unique"
        )
    entries: list[dict[str, object]] = []
    seals: list[SourceFileSeal] = []
    directory_paths: set[Path] = {project_root}
    total_size = 0
    for relative_path, role in closure:
        if (
            not relative_path
            or relative_path.startswith("/")
            or ".." in Path(relative_path).parts
            or not role
        ):
            raise ReleaseSourceReceiptError(
                "release source closure entry is invalid"
            )
        path = project_root / relative_path
        contents, file_status = _read_source_file(
            project_root,
            relative_path,
        )
        total_size += len(contents)
        if total_size > _MAXIMUM_TOTAL_SOURCE_BYTES:
            raise ReleaseSourceReceiptError(
                "release source tracked files exceed the aggregate limit"
            )
        current_parent = path.parent
        while current_parent != project_root:
            directory_paths.add(current_parent)
            current_parent = current_parent.parent
        digest = hashlib.sha256(contents).hexdigest()
        entries.append(
            {
                "path": relative_path,
                "role": role,
                "sha256": digest,
                "size": len(contents),
            }
        )
        seals.append(
            SourceFileSeal(
                path=path,
                relative_path=relative_path,
                sha256=digest,
                size=len(contents),
                device=file_status.st_dev,
                inode=file_status.st_ino,
                mtime_ns=file_status.st_mtime_ns,
                ctime_ns=file_status.st_ctime_ns,
            )
        )
    python_parents = {
        (project_root / relative_path).parent
        for relative_path, _role in closure
        if relative_path.endswith(".py")
    }
    for parent in python_parents:
        if (
            os.path.lexists(parent / "__pycache__")
            or any(parent.glob("*.pyc"))
        ):
            raise ReleaseSourceReceiptError(
                "release source contains executable Python bytecode cache"
            )
    closure_digest = hashlib.sha256(_canonical_json(entries)).hexdigest()
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "project": "NeAntik",
        "repositoryClaim": "AffPapa/neantik",
        "git": {
            "objectFormat": object_format,
            "commit": commit,
            "tree": tree,
            "worktreeState": worktree_state,
            "sourceRootRelativePath": relative_project_root.as_posix(),
        },
        "digestAlgorithm": "sha256",
        "closure": entries,
        "closureSHA256": closure_digest,
    }
    return ReleaseSourceSnapshot(
        project_root=project_root,
        payload=payload,
        files=tuple(seals),
        directories=tuple(
            _seal_source_directory(path)
            for path in sorted(directory_paths)
        ),
    )


def assert_release_source_unchanged(
    snapshot: ReleaseSourceSnapshot,
) -> None:
    closure_payload = snapshot.payload.get("closure")
    if not isinstance(closure_payload, list):
        raise ReleaseSourceReceiptError(
            "release source receipt closure is invalid"
        )
    closure: list[tuple[str, str]] = []
    for entry in closure_payload:
        if not isinstance(entry, dict):
            raise ReleaseSourceReceiptError(
                "release source receipt closure is invalid"
            )
        path = entry.get("path")
        role = entry.get("role")
        if not isinstance(path, str) or not isinstance(role, str):
            raise ReleaseSourceReceiptError(
                "release source receipt closure is invalid"
            )
        closure.append((path, role))
    current = capture_release_source(
        snapshot.project_root,
        closure=tuple(closure),
    )
    if current.payload != snapshot.payload:
        raise ReleaseSourceReceiptError(
            "release source changed during the transaction"
        )
    for expected, observed in zip(
        snapshot.files,
        current.files,
        strict=True,
    ):
        if (
            expected.path != observed.path
            or expected.device != observed.device
            or expected.inode != observed.inode
            or expected.mtime_ns != observed.mtime_ns
            or expected.ctime_ns != observed.ctime_ns
            or expected.sha256 != observed.sha256
            or expected.size != observed.size
        ):
            raise ReleaseSourceReceiptError(
                "release source changed during the transaction"
            )
    for expected, observed in zip(
        snapshot.directories,
        current.directories,
        strict=True,
    ):
        if expected != observed:
            raise ReleaseSourceReceiptError(
                "release source directory changed during the transaction"
            )


def runtime_build_evidence_from_manifest(
    snapshot: ReleaseSourceSnapshot,
    manifest: Path,
) -> dict[str, object]:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(manifest, flags)
    except OSError as error:
        raise ReleaseSourceReceiptError(
            "candidate manifest is unavailable for source binding"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or before.st_size <= 0
            or before.st_size > 16 * 1024 * 1024
        ):
            raise ReleaseSourceReceiptError(
                "candidate manifest is unsafe for source binding"
            )
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > 16 * 1024 * 1024:
                raise ReleaseSourceReceiptError(
                    "candidate manifest is too large for source binding"
                )
            chunks.append(chunk)
        raw = b"".join(chunks)
        after = os.fstat(descriptor)
    except OSError as error:
        raise ReleaseSourceReceiptError(
            "candidate manifest could not be read for source binding"
        ) from error
    finally:
        os.close(descriptor)
    if (
        len(raw) != before.st_size
        or before.st_dev != after.st_dev
        or before.st_ino != after.st_ino
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
    ):
        raise ReleaseSourceReceiptError(
            "candidate manifest changed during source binding"
        )

    def reject_duplicates(
        pairs: list[tuple[str, object]],
    ) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ReleaseSourceReceiptError(
                    "candidate manifest contains duplicate keys"
                )
            result[key] = value
        return result

    try:
        payload = json.loads(raw, object_pairs_hook=reject_duplicates)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ReleaseSourceReceiptError(
            "candidate manifest is invalid for source binding"
        ) from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 3:
        raise ReleaseSourceReceiptError(
            "candidate manifest schema is invalid for source binding"
        )
    critical = payload.get("criticalFiles")
    expected_critical = {
        "buildArguments",
        "managerExecutable",
        "managerInfoPlist",
        "runtimeCandidateLock",
        "runtimeExecutable",
        "runtimeFramework",
        "runtimeInfoPlist",
        "runtimeVerification",
        "sourceContract",
        "sourceProvenance",
    }
    if not isinstance(critical, dict) or set(critical) != expected_critical:
        raise ReleaseSourceReceiptError(
            "candidate manifest critical-file binding is invalid"
        )
    selected = {
        "buildArguments": "buildArgumentsSHA256",
        "runtimeCandidateLock": "runtimeCandidateLockSHA256",
        "runtimeVerification": "runtimeVerificationSHA256",
        "sourceContract": "sourceContractSHA256",
        "sourceProvenance": "sourceProvenanceSHA256",
    }
    result: dict[str, str | int] = {
        "schemaVersion": 1,
        "status": "candidate-bound-reviewed-source",
        "binding": "candidate-manifest-critical-files",
    }
    for manifest_key, receipt_key in selected.items():
        entry = critical.get(manifest_key)
        if (
            not isinstance(entry, dict)
            or set(entry) != {"bundlePath", "sha256"}
            or not isinstance(entry.get("bundlePath"), str)
            or not isinstance(entry.get("sha256"), str)
            or len(entry["sha256"]) != 64
            or any(
                character not in "0123456789abcdef"
                for character in entry["sha256"]
            )
        ):
            raise ReleaseSourceReceiptError(
                "candidate manifest runtime binding is invalid"
            )
        result[receipt_key] = entry["sha256"]
    toolchain_entries = [
        entry
        for entry in snapshot.payload["closure"]  # type: ignore[index]
        if entry["path"] == "runtime/chromium-152-toolchain-lock.json"
    ]
    if len(toolchain_entries) != 1:
        raise ReleaseSourceReceiptError(
            "reviewed toolchain lock is missing from release source"
        )
    result["reviewedToolchainLockSHA256"] = toolchain_entries[0]["sha256"]
    return result
