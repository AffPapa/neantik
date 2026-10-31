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


def package(project: Path, evidence: Path, inherited_evidence: Path | None = None) -> None:
    current = baseline_inputs(project, evidence)
    destination = evidence / "release-security-baseline.json"
    inherited_stat = None
    if destination.exists() or destination.is_symlink():
        # Never overwrite a link or an unrelated pre-existing release input.
        if read_regular(destination) == current:
            return
        if inherited_evidence is None or inherited_evidence.resolve() == evidence.resolve():
            raise ValueError("Release baseline already exists with different bytes")
        # Manager-only packaging copies the previous signed app into a fresh
        # unsigned candidate. Only its exact inherited publication observation
        # can be replaced; the source and historical runtime binding stay intact.
        source = inherited_evidence / "release-security-baseline.json"
        inherited = read_regular(source)
        inherited_stat = destination.stat()
        if inherited_stat.st_nlink != 1 or read_regular(destination) != inherited:
            raise ValueError("Inherited release baseline differs or is shared")
    fd, name = tempfile.mkstemp(prefix=".release-baseline-", dir=evidence)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(current)
            stream.flush()
            os.fsync(stream.fileno())
        if inherited_stat is None:
            os.link(temporary, destination)  # Exclusive publication, no overwrite.
        else:
            observed = destination.lstat()
            if (observed.st_dev, observed.st_ino, observed.st_size, observed.st_mtime_ns, observed.st_ctime_ns) != (inherited_stat.st_dev, inherited_stat.st_ino, inherited_stat.st_size, inherited_stat.st_mtime_ns, inherited_stat.st_ctime_ns) or read_regular(destination) != inherited or read_regular(source) != inherited:
                raise ValueError("Inherited baseline changed during packaging")
            os.replace(temporary, destination)  # Fresh unsigned candidate only.
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--inherited-evidence", type=Path)
    args = parser.parse_args()
    if args.verify_only:
        if args.inherited_evidence is not None: parser.error("Read-only verification does not accept inherited evidence")
        verify(args.project_root, args.evidence)
    else:
        package(args.project_root, args.evidence, args.inherited_evidence)
    print("PASS: historical runtime baseline retained; fresh release baseline packaged separately.")
