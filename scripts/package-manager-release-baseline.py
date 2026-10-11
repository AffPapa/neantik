#!/usr/bin/env python3
"""Keep the runtime report's baseline separate from today's publication gate.

The caller has already verified today's baseline and official reference. This
step preserves the immutable runtime report and packages that fresh observation
as separate evidence before the outer app is signed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

from runtime_historical_baseline import bound_baseline_path


def read_regular(path: Path) -> bytes:
    if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
        raise ValueError("Baseline evidence must be a regular file")
    data = path.read_bytes()
    if len(data) > 1024 * 1024:
        raise ValueError("Baseline evidence exceeds the limit")
    return data


def baseline_inputs(project: Path, evidence: Path) -> bytes:
    if evidence.is_symlink() or not evidence.is_dir():
        raise ValueError("Unsafe evidence directory")
    report = json.loads(read_regular(evidence / "runtime-verification.json"))
    digest = report.get("securityBaselineSHA256")
    historical = bound_baseline_path(project / "runtime", digest)
    packaged = read_regular(evidence / "security-baseline.json")
    if hashlib.sha256(packaged).hexdigest() != digest or packaged != read_regular(historical):
        raise ValueError("Packaged historical baseline differs from runtime report")
    return read_regular(project / "runtime/security-baseline.json")


def verify(project: Path, evidence: Path) -> None:
    current = baseline_inputs(project, evidence)
    if read_regular(evidence / "release-security-baseline.json") != current:
        raise ValueError("Packaged release baseline differs from current publication gate")


def package(project: Path, evidence: Path) -> None:
    current = baseline_inputs(project, evidence)
    destination = evidence / "release-security-baseline.json"
    if destination.exists() or destination.is_symlink():
        # Never overwrite a link or an unrelated pre-existing release input.
        if read_regular(destination) != current:
            raise ValueError("Release baseline already exists with different bytes")
        return
    fd, name = tempfile.mkstemp(prefix=".release-baseline-", dir=evidence)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(current)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, destination)  # Exclusive publication, no overwrite.
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    (verify if args.verify_only else package)(args.project_root, args.evidence)
    print("PASS: historical runtime baseline retained; fresh release baseline packaged separately.")
