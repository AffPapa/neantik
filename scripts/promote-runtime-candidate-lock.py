#!/usr/bin/env python3
"""Explicitly promote a source-only candidate after fresh Metal verification."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from runtime_candidate_lock import PROJECT_ROOT, verify_candidate_lock
from runtime_source_provenance import (
    SourceProvenanceError,
    atomic_write_json,
    sha256_file,
)


SHA256_LENGTH = 64


def load_report(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SourceProvenanceError("Runtime report must be a JSON object")
    return value


def args_are_metal(path: Path) -> bool:
    lines = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("angle_enable_metal")
    ]
    return lines == ["angle_enable_metal = true"]


def validate_report_binding(
    candidate_lock: Path,
    provenance: Path,
    args_gn: Path,
    report_path: Path,
    *,
    project_root: Path = PROJECT_ROOT,
) -> None:
    expected_args = (
        provenance.parent / "src" / "out" / "Default" / "args.gn"
    )
    if args_gn.resolve() != expected_args.resolve():
        raise SourceProvenanceError(
            "Candidate promotion requires canonical build-root "
            "src/out/Default/args.gn"
        )
    candidate = verify_candidate_lock(
        candidate_lock,
        provenance,
        project_root=project_root,
    )
    if not args_are_metal(args_gn):
        raise SourceProvenanceError(
            "Candidate promotion requires fresh angle_enable_metal=true evidence"
        )
    report = load_report(report_path)
    candidate_sha = sha256_file(candidate_lock)
    expected = {
        "schemaVersion": 3,
        "gpuMode": "metal",
        "candidateLockSHA256": candidate_sha,
        "sourceLockSHA256": candidate_sha,
        "sourceContractSHA256": candidate["sourceContractSHA256"],
        "sourceProvenanceSHA256": sha256_file(provenance),
        "chromiumVersion": candidate["fingerprintChromium"]["chromiumVersion"],
    }
    for key, expected_value in expected.items():
        if report.get(key) != expected_value:
            raise SourceProvenanceError(
                f"Runtime report cannot promote candidate: {key} mismatch"
            )
    build_arguments = report.get("buildArguments")
    if (
        not isinstance(build_arguments, dict)
        or set(build_arguments) != {"sha256"}
        or build_arguments["sha256"] != sha256_file(args_gn)
    ):
        raise SourceProvenanceError(
            "Runtime report cannot promote candidate: buildArguments mismatch"
        )
    for label in ("executable", "framework"):
        item = report.get(label)
        digest = item.get("sha256") if isinstance(item, dict) else None
        if (
            not isinstance(digest, str)
            or len(digest) != SHA256_LENGTH
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise SourceProvenanceError(
                f"Runtime report cannot promote candidate: invalid {label} SHA-256"
            )


def promote(
    candidate_lock: Path,
    provenance: Path,
    runtime_app: Path,
    args_gn: Path,
    runtime_report: Path,
    *,
    project_root: Path = PROJECT_ROOT,
) -> Path:
    project_root = project_root.resolve()
    published_lock = (
        project_root / "runtime" / "fingerprint-chromium.lock.json"
    )
    for path, label in (
        (candidate_lock, "candidate lock"),
        (provenance, "source provenance"),
        (runtime_app, "runtime app"),
        (args_gn, "args.gn"),
        (runtime_report, "runtime report"),
    ):
        if not path.is_absolute() or not path.exists() or path.is_symlink():
            raise SourceProvenanceError(
                f"Promotion {label} must be an existing absolute non-symlink path"
            )
    if candidate_lock.resolve() == published_lock.resolve():
        raise SourceProvenanceError(
            "Promotion candidate must be separate from the published lock"
        )
    validate_report_binding(
        candidate_lock,
        provenance,
        args_gn,
        runtime_report,
        project_root=project_root,
    )
    with tempfile.TemporaryDirectory(prefix="neantik-candidate-promotion-") as temp:
        fresh_report = Path(temp) / "fresh-runtime-report.json"
        subprocess.run(
            [
                str(project_root / "scripts" / "verify-built-runtime.sh"),
                str(runtime_app),
                str(fresh_report),
                str(args_gn),
                str(provenance),
                str(candidate_lock),
            ],
            check=True,
        )
        subprocess.run(
            [
                sys.executable,
                str(project_root / "scripts" / "verify-runtime-report-consistency.py"),
                str(runtime_report),
                str(fresh_report),
            ],
            check=True,
        )
        validate_report_binding(
            candidate_lock,
            provenance,
            args_gn,
            fresh_report,
            project_root=project_root,
        )
    candidate = load_report(candidate_lock)
    atomic_write_json(published_lock, candidate)
    if published_lock.read_bytes() != candidate_lock.read_bytes():
        raise SourceProvenanceError(
            "Promoted lock bytes differ from verified candidate lock"
        )
    return published_lock


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail-closed manual promotion of a verified source-only candidate "
            "lock after a fresh Metal binary report."
        )
    )
    parser.add_argument("candidate_lock", type=Path)
    parser.add_argument("provenance", type=Path)
    parser.add_argument("runtime_app", type=Path)
    parser.add_argument("args_gn", type=Path)
    parser.add_argument("runtime_report", type=Path)
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument(
        "--confirm-promote-source-lock",
        action="store_true",
        help="Required explicit acknowledgement that the published lock changes.",
    )
    args = parser.parse_args()
    if not args.confirm_promote_source_lock:
        print(
            "Promotion refused: pass --confirm-promote-source-lock only after "
            "reviewing the fresh Metal runtime report.",
            file=sys.stderr,
        )
        return 2
    try:
        destination = promote(
            args.candidate_lock,
            args.provenance,
            args.runtime_app,
            args.args_gn,
            args.runtime_report,
            project_root=args.project_root,
        )
    except (
        OSError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
        SourceProvenanceError,
    ) as error:
        print(f"Candidate promotion failed: {error}", file=sys.stderr)
        return 1
    print(f"Promoted verified candidate lock: {destination}")
    print(f"SHA-256: {sha256_file(destination)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
