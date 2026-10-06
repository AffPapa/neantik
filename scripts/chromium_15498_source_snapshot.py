#!/usr/bin/env python3
"""Create and verify a path-free snapshot of Chromium 154.0.8037.98 inputs."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any


VERSION = "154.0.8037.98"
COMMIT = "b859317bf11f6be47f9b7799ec690a0a42a1fb33"
TREE = "e3eac82f3bb5479e80ab245c514083b5db4fedf3"


class SnapshotError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(source_root: Path, *args: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(source_root), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise SnapshotError(f"git source inventory failed: {args[0]}") from error


def version_from_file(path: Path) -> str:
    values = dict(
        line.split("=", 1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line
    )
    try:
        return ".".join(values[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH"))
    except KeyError as error:
        raise SnapshotError("Chromium VERSION file is incomplete") from error


def build_snapshot(source_root: Path, args_gn: Path) -> dict[str, Any]:
    if source_root.is_symlink() or not source_root.is_dir():
        raise SnapshotError("source root must be a real directory")
    source_root = source_root.resolve()
    args_gn = args_gn.resolve(strict=True)
    try:
        args_relative = args_gn.relative_to(source_root).as_posix()
    except ValueError as error:
        raise SnapshotError("args.gn must be inside the Chromium checkout") from error
    if args_relative.split("/", 1)[0] != "out" or args_gn.name != "args.gn":
        raise SnapshotError("args.gn must be under out/<configuration>/args.gn")

    commit = git(source_root, "rev-parse", "HEAD").decode().strip()
    tree = git(source_root, "rev-parse", "HEAD^{tree}").decode().strip()
    version = version_from_file(source_root / "chrome" / "VERSION")
    if (commit, tree, version) != (COMMIT, TREE, VERSION):
        raise SnapshotError("source checkout does not match locked Chromium 154")

    names: list[str] = []
    for directory, directory_names, file_names in os.walk(source_root, topdown=True, followlinks=False):
        current = Path(directory)
        relative_directory = current.relative_to(source_root).as_posix()
        symlink_directories = [
            name for name in directory_names if (current / name).is_symlink()
        ]
        names.extend(
            (current / name).relative_to(source_root).as_posix()
            for name in symlink_directories
        )
        directory_names[:] = [
            name
            for name in directory_names
            if name != ".git"
            and not (relative_directory == "." and name == "out")
            and not (current / name).is_symlink()
        ]
        for name in file_names:
            if name == ".git":
                continue
            names.append((current / name).relative_to(source_root).as_posix())
    entries: list[dict[str, Any]] = []
    deleted: list[str] = []
    seen: set[str] = set()
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        path = source_root / name
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            target = os.fsencode(os.readlink(path))
            entries.append(
                {
                    "kind": "symlink",
                    "path": name,
                    "mode": stat.S_IMODE(info.st_mode),
                    "targetLength": len(target),
                    "targetSHA256": sha256(target),
                }
            )
        elif stat.S_ISREG(info.st_mode):
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            entries.append(
                {
                    "kind": "file",
                    "path": name,
                    "mode": stat.S_IMODE(info.st_mode),
                    "sizeBytes": info.st_size,
                    "sha256": digest.hexdigest(),
                }
            )
        else:
            raise SnapshotError(f"unsupported source input type: {name}")

    deleted = sorted(
        os.fsdecode(raw_name)
        for raw_name in git(source_root, "ls-files", "--deleted", "-z").split(b"\0")
        if raw_name
    )

    entries.sort(key=lambda item: item["path"])
    args_digest = hashlib.sha256(args_gn.read_bytes()).hexdigest()
    return {
        "schemaVersion": 1,
        "recordType": "chromium-source-snapshot",
        "targetChromiumVersion": VERSION,
        "officialChromiumBase": {"commit": commit, "tree": tree},
        "argsGN": {"relativePath": args_relative, "sha256": args_digest},
        "sourceFileCount": len(entries),
        "deletedPathCount": len(deleted),
        "entries": entries,
        "deletedPaths": deleted,
        "releaseReady": False,
        "provenanceLimit": (
            "Exact current checkout snapshot only; this does not recreate or "
            "prove missing historical patch replay evidence."
        ),
    }


def compact_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Bind the complete inventory without shipping its potentially huge JSON."""
    if snapshot.get("schemaVersion") != 1:
        raise SnapshotError("compact snapshot requires a full schema 1 inventory")
    entries = snapshot.get("entries")
    deleted = snapshot.get("deletedPaths")
    if (
        not isinstance(entries, list)
        or not isinstance(deleted, list)
        or len(entries) != snapshot.get("sourceFileCount")
        or len(deleted) != snapshot.get("deletedPathCount")
    ):
        raise SnapshotError("source inventory counts are inconsistent")
    result = {key: copy.deepcopy(value) for key, value in snapshot.items()
              if key not in {"entries", "deletedPaths"}}
    result["schemaVersion"] = 2
    result["inventoryDigestAlgorithm"] = "sha256-canonical-json-v1"
    for key, values in (("entriesSHA256", entries), ("deletedPathsSHA256", deleted)):
        digest = hashlib.sha256()
        encoder = json.JSONEncoder(sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        for chunk in encoder.iterencode(values):
            digest.update(chunk.encode("utf-8"))
        result[key] = digest.hexdigest()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("args_gn", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--compact", action="store_true",
                        help="write inventory digests; verification still reads all source inputs")
    args = parser.parse_args()
    try:
        if not args.output.is_absolute() or args.output.is_symlink():
            raise SnapshotError("snapshot output must be an absolute non-symlink path")
        current = build_snapshot(args.source_root, args.args_gn)
        if args.verify:
            stored = json.loads(args.output.read_text(encoding="utf-8"))
            if stored.get("schemaVersion") == 2:
                current = compact_snapshot(current)
            if stored != current:
                raise SnapshotError("live source or args.gn differs from frozen snapshot")
            print(
                "PASS: Chromium source snapshot matches "
                f"{current['sourceFileCount']} files and "
                f"{current['deletedPathCount']} deleted paths"
            )
        else:
            if args.compact:
                current = compact_snapshot(current)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_name(args.output.name + ".tmp")
            temporary.write_text(
                json.dumps(current, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            temporary.replace(args.output)
            print(f"Chromium source snapshot exported: {args.output}")
    except (OSError, UnicodeError, json.JSONDecodeError, SnapshotError) as error:
        print(f"Chromium source snapshot failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
