"""Admit a registered private candidate directory without replacing the live app."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid

from notary_transaction_state import ensure_private_directory


class CandidateLocationError(RuntimeError):
    pass


def canonical(path: Path) -> Path:
    path = path.absolute()
    if path != path.resolve():
        raise CandidateLocationError("Candidate location must be canonical")
    return path


def validate(project: Path, root: Path) -> Path:
    """Directory inode and private ownership are a location gate, not provenance."""
    project, root = canonical(project), canonical(root)
    parent = project / "dist/private/candidates"
    if root.parent != parent or not re.fullmatch(r"[0-9a-f]{32}", root.name):
        raise CandidateLocationError("Candidate location is outside the registered namespace")
    for directory in (project / "dist/private", parent, root):
        canonical(directory)
        status = directory.lstat()
        if (not stat.S_ISDIR(status.st_mode) or status.st_uid != os.geteuid() or
                stat.S_IMODE(status.st_mode) != 0o700):
            raise CandidateLocationError("Candidate directory is not private and owned")
    marker = root / "location.json"
    descriptor = os.open(marker, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or
                before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o400 or
                before.st_size <= 0 or before.st_size > 4096):
            raise CandidateLocationError("Candidate registration is unsafe")
        raw = os.read(descriptor, 4097)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    # Reading may update st_atime. Compare the inode and write-sensitive
    # metadata only, so an ordinary access-time update is not a mutation race.
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid",
                     "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields) or len(raw) != before.st_size:
        raise CandidateLocationError("Candidate registration changed during reading")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise CandidateLocationError("Candidate registration has duplicate fields")
            result[key] = value
        return result
    payload = json.loads(raw, object_pairs_hook=unique)
    directory = root.lstat()
    expected = {"schemaVersion": 1, "project": str(project), "candidateID": root.name,
                "directoryDevice": directory.st_dev, "directoryInode": directory.st_ino}
    if (not isinstance(payload, dict) or payload != expected or
            any(type(payload.get(key)) is not int for key in
                ("schemaVersion", "directoryDevice", "directoryInode"))):
        raise CandidateLocationError("Candidate registration does not match its directory")
    return root


def create(project: Path) -> Path:
    # Deferred to avoid a cycle: the ZIP orchestrator also imports this validator.
    from notarize_direct_transaction import write_private_json
    project = canonical(project)
    dist = project / "dist"
    if (not dist.is_dir() or dist.is_symlink() or dist.stat().st_uid != os.geteuid() or
            dist.stat().st_mode & 0o022):
        raise CandidateLocationError("Project dist directory is unsafe")
    parent = dist / "private/candidates"
    canonical(parent)
    ensure_private_directory(parent.parent)
    ensure_private_directory(parent)
    root = parent / uuid.uuid4().hex
    root.mkdir(mode=0o700)
    status = root.lstat()
    write_private_json(root / "location.json", {
        "schemaVersion": 1, "project": str(project), "candidateID": root.name,
        "directoryDevice": status.st_dev, "directoryInode": status.st_ino,
    })
    return validate(project, root)


def validate_inputs(project: Path, app: Path, inputs: dict[str, Path]) -> Path:
    """Legacy gate stays exact; alternate paths need a registered location."""
    if app.resolve() == (project / "dist/NeAntik.app").resolve():
        return project / "dist"
    root = validate(project, app.parent)
    if canonical(app) != root / "NeAntik.app":
        raise CandidateLocationError("Registered candidate must retain NeAntik.app basename")
    for expected_name, path in inputs.items():
        if canonical(path) != root / expected_name:
            raise CandidateLocationError("Registered candidate inputs do not share its location")
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--create", action="store_true")
    group.add_argument("--validate", type=Path)
    args = parser.parse_args()
    try:
        root = create(args.project_root) if args.create else validate(args.project_root, args.validate)
        print(root)
    except (CandidateLocationError, OSError, ValueError):
        print("Candidate location refused; no existing application was changed", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
