#!/usr/bin/env python3
"""Export deterministic evidence for an owned Chromium macOS source port.

This is source-input evidence only. It does not qualify a binary, signing,
notarization, or release. The manifest deliberately records untracked inputs
as well as the tracked diff because Chromium packaging materializes generated
and downloaded source files outside the upstream Git tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path, PurePosixPath


class ManifestError(ValueError):
    pass


def git(root: Path, *args: str, binary: bool = False) -> bytes | str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise ManifestError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout if binary else result.stdout.decode("utf-8").strip()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(value: str) -> str:
    if not value or "\\" in value:
        raise ManifestError(f"unsafe source path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ManifestError(f"unsafe source path: {value!r}")
    return path.as_posix()


def excluded(relative: str, prefixes: tuple[str, ...]) -> bool:
    return any(relative == prefix or relative.startswith(prefix + "/") for prefix in prefixes)


def inventory(root: Path, prefixes: tuple[str, ...]) -> list[dict[str, object]]:
    raw = git(root, "ls-files", "--others", "--exclude-standard", "-z", binary=True)
    assert isinstance(raw, bytes)
    entries: list[dict[str, object]] = []
    for encoded in filter(None, raw.split(b"\0")):
        relative = safe_relative(os.fsdecode(encoded))
        if excluded(relative, prefixes):
            continue
        if relative.endswith((".rej", ".orig")):
            raise ManifestError(
                "patch rejection artifact is not an accepted source input: "
                + relative
            )
        path = root / relative
        stat = path.lstat()
        if path.is_symlink():
            entries.append(
                {
                    "path": relative,
                    "kind": "symlink",
                    "mode": stat.st_mode & 0o7777,
                    "target": os.readlink(path),
                }
            )
        elif path.is_file():
            entries.append(
                {
                    "path": relative,
                    "kind": "file",
                    "mode": stat.st_mode & 0o7777,
                    "size": stat.st_size,
                    "sha256": sha256_file(path),
                }
            )
        elif path.is_dir():
            nested_head = None
            nested_git = path / ".git"
            if nested_git.exists():
                try:
                    nested_head = str(git(path, "rev-parse", "HEAD"))
                except ManifestError:
                    nested_head = None
            entries.append(
                {
                    "path": relative,
                    "kind": "directory",
                    "mode": stat.st_mode & 0o7777,
                    "nestedGitHEAD": nested_head,
                }
            )
        else:
            raise ManifestError(f"unsupported untracked input: {relative}")
    entries.sort(key=lambda item: str(item["path"]))
    return entries


def build_manifest(root: Path, prefixes: tuple[str, ...]) -> dict[str, object]:
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise ManifestError("source root must be an absolute non-symlink directory")
    top = Path(str(git(root, "rev-parse", "--show-toplevel"))).resolve()
    if top != root.resolve():
        raise ManifestError("source root must be the exact Git repository root")

    tracked_diff = git(
        root,
        "-c",
        "core.autocrlf=false",
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--binary",
        "--full-index",
        "--no-renames",
        "HEAD",
        "--",
        binary=True,
    )
    assert isinstance(tracked_diff, bytes)
    files = inventory(root, prefixes)
    inventory_bytes = json.dumps(
        files, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {
        "schemaVersion": 1,
        "sourceMode": "owned-macos-packaging-port",
        "binaryBindingStatus": "pending-new-build",
        "sourceRoot": str(root),
        "git": {
            "commit": str(git(root, "rev-parse", "HEAD")),
            "tree": str(git(root, "rev-parse", "HEAD^{tree}")),
            "trackedDiffSHA256": sha256_bytes(tracked_diff),
            "trackedDiffBytes": len(tracked_diff),
        },
        "excludedPrefixes": list(prefixes),
        "untrackedInventorySHA256": sha256_bytes(inventory_bytes),
        "untrackedFileCount": len(files),
        "untrackedInputs": files,
        "policy": (
            "Source-input evidence only. This document makes no claim about "
            "runtime behavior, security qualification, signing, notarization, "
            "publication, or release readiness."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--exclude-prefix",
        action="append",
        default=[],
        help="Relative source prefix to omit from the untracked inventory.",
    )
    args = parser.parse_args()
    try:
        root = args.source_root.resolve()
        output = args.output.resolve()
        if not output.is_absolute():
            raise ManifestError("output must be absolute")
        prefixes = tuple(safe_relative(value.rstrip("/")) for value in args.exclude_prefix)
        manifest = build_manifest(root, prefixes)
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.name + ".tmp")
        temporary.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, output)
    except (ManifestError, OSError) as error:
        print(f"Chromium 153 port manifest export failed: {error}", file=sys.stderr)
        return 1
    print(f"Chromium 153 port input manifest: {output}")
    print(f"Untracked inputs: {manifest['untrackedFileCount']}")
    print(f"Inventory SHA-256: {manifest['untrackedInventorySHA256']}")
    print("Binary binding: pending-new-build")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
