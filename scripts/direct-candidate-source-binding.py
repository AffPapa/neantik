#!/usr/bin/env python3
"""Bind one prepared Direct candidate to the exact clean Git source commit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
from pathlib import Path


MAXIMUM_BINDING_BYTES = 4096
HEX_40 = re.compile(r"[0-9a-f]{40}")
HEX_64 = re.compile(r"[0-9a-f]{64}")


class CandidateSourceBindingError(RuntimeError):
    pass


def run_git(project_root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(project_root), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise CandidateSourceBindingError("Git source query failed")
    return result.stdout.strip()


def checked_project_root(project_root: Path) -> Path:
    root = project_root.resolve()
    if not root.is_dir():
        raise CandidateSourceBindingError("project root is unavailable")
    top_level = Path(run_git(root, "rev-parse", "--show-toplevel")).resolve()
    if top_level != root:
        raise CandidateSourceBindingError(
            "project root must be the exact Git worktree root"
        )
    if run_git(root, "status", "--porcelain", "--untracked-files=no"):
        raise CandidateSourceBindingError(
            "tracked release source is not clean"
        )
    return root


def regular_file_bytes(path: Path, maximum_bytes: int) -> bytes:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise CandidateSourceBindingError(
            f"{path.name} is unavailable"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or before.st_size <= 0
            or before.st_size > maximum_bytes
        ):
            raise CandidateSourceBindingError(
                f"{path.name} is unsafe"
            )
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum_bytes:
                break
        raw = b"".join(chunks)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        len(raw) != before.st_size
        or len(raw) > maximum_bytes
        or before.st_dev != after.st_dev
        or before.st_ino != after.st_ino
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
    ):
        raise CandidateSourceBindingError(
            f"{path.name} changed while it was read"
        )
    return raw


def expected_payload(
    project_root: Path,
    manifest: Path,
) -> dict[str, object]:
    root = checked_project_root(project_root)
    commit = run_git(root, "rev-parse", "HEAD")
    tree = run_git(root, "rev-parse", "HEAD^{tree}")
    if not HEX_40.fullmatch(commit) or not HEX_40.fullmatch(tree):
        raise CandidateSourceBindingError(
            "unsupported Git object format"
        )
    manifest_raw = regular_file_bytes(manifest, 16 * 1024 * 1024)
    return {
        "commit": commit,
        "manifestSHA256": hashlib.sha256(manifest_raw).hexdigest(),
        "schemaVersion": 1,
        "tree": tree,
    }


def encoded_payload(payload: dict[str, object]) -> bytes:
    return json.dumps(
        payload,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def create_binding(
    project_root: Path,
    manifest: Path,
    binding: Path,
) -> str:
    if binding.exists() or binding.is_symlink():
        raise CandidateSourceBindingError(
            "candidate source binding already exists"
        )
    payload = expected_payload(project_root, manifest)
    raw = encoded_payload(payload)
    binding.parent.mkdir(parents=True, exist_ok=True)
    temporary_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{binding.name}.",
        dir=binding.parent,
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(temporary_descriptor, 0o600)
        with os.fdopen(temporary_descriptor, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, binding)
    finally:
        temporary.unlink(missing_ok=True)
    return hashlib.sha256(raw).hexdigest()


def verify_binding(
    project_root: Path,
    manifest: Path,
    binding: Path,
) -> str:
    raw = regular_file_bytes(binding, MAXIMUM_BINDING_BYTES)
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise CandidateSourceBindingError(
            "candidate source binding is invalid"
        ) from error
    expected = expected_payload(project_root, manifest)
    if payload != expected or raw != encoded_payload(expected):
        raise CandidateSourceBindingError(
            "prepared candidate does not match the exact current source commit"
        )
    digest = hashlib.sha256(raw).hexdigest()
    if not HEX_64.fullmatch(digest):
        raise CandidateSourceBindingError(
            "candidate source binding digest is invalid"
        )
    return digest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("create", "verify"))
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--binding", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.action == "create":
            digest = create_binding(
                arguments.project_root,
                arguments.manifest,
                arguments.binding,
            )
        else:
            digest = verify_binding(
                arguments.project_root,
                arguments.manifest,
                arguments.binding,
            )
    except CandidateSourceBindingError as error:
        print(f"Candidate source binding failed: {error}", file=os.sys.stderr)
        return 65
    print(f"PASS: candidate source binding verified; SHA-256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
