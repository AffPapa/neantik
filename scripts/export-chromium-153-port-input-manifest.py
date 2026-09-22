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
import re
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


def require_absolute_directory(path: Path, label: str) -> Path:
    resolved = path.resolve()
    if not path.is_absolute() or path.is_symlink() or not resolved.is_dir():
        raise ManifestError(f"{label} must be an absolute non-symlink directory")
    return resolved


def bind_built_candidate(app_path: Path, args_gn_path: Path) -> dict[str, object]:
    """Bind source-input evidence to one freshly built, unsigned candidate.

    This intentionally proves only the relationship between the exported
    source tree and a local build candidate. It does not attest signing,
    notarization, Gatekeeper, runtime behavior, or release readiness.
    """
    app_path = require_absolute_directory(app_path, "binary app")
    args_gn_path = args_gn_path.resolve()
    if not args_gn_path.is_absolute() or not args_gn_path.is_file():
        raise ManifestError("args.gn must be an absolute regular file")

    executable = app_path / "Contents" / "MacOS" / "NeAntik Browser"
    if not executable.is_file():
        raise ManifestError(f"built candidate executable is missing: {executable}")

    version_result = subprocess.run(
        [str(executable), "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=30,
    )
    if version_result.returncode != 0:
        detail = version_result.stderr.strip() or version_result.stdout.strip()
        raise ManifestError(f"candidate --version failed: {detail}")
    observed_version = version_result.stdout.strip()
    if not observed_version:
        raise ManifestError("candidate --version returned no version")

    version_file = app_path.parents[2] / "chrome" / "VERSION"
    if not version_file.is_file():
        raise ManifestError(f"candidate source VERSION is missing: {version_file}")
    source_pairs = dict(
        line.split("=", 1)
        for line in version_file.read_text(encoding="utf-8").splitlines()
        if "=" in line
    )
    source_version = ".".join(
        source_pairs[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH")
    )
    if source_version not in observed_version:
        raise ManifestError(
            f"candidate version {observed_version!r} does not contain source "
            f"version {source_version}"
        )

    file_result = subprocess.run(
        ["/usr/bin/file", str(executable)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if file_result.returncode != 0 or "arm64" not in file_result.stdout:
        raise ManifestError(
            "candidate executable is not proven arm64: "
            + file_result.stdout.strip()
        )

    args_text = args_gn_path.read_text(encoding="utf-8")
    if not re.search(r"(?m)^\s*target_cpu\s*=\s*\"arm64\"\s*$", args_text):
        raise ManifestError("args.gn does not pin target_cpu=arm64")
    if not re.search(
        r"(?m)^\s*angle_enable_metal\s*=\s*true\s*$", args_text
    ):
        raise ManifestError("args.gn does not enable angle_enable_metal=true")

    return {
        "status": "bound-to-built-candidate",
        "candidateAppPath": str(app_path),
        "candidateExecutableSHA256": sha256_file(executable),
        "candidateExecutableSize": executable.stat().st_size,
        "candidateVersionOutput": observed_version,
        "sourceVersion": source_version,
        "architecture": "arm64",
        "angleEnableMetal": True,
        "argsGNPath": str(args_gn_path),
        "argsGNSHA256": sha256_file(args_gn_path),
        "policy": (
            "Local unsigned build-candidate binding only. This does not attest "
            "signing, notarization, Gatekeeper, runtime behavior, publication, "
            "or release readiness."
        ),
    }


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


def build_manifest(
    root: Path,
    prefixes: tuple[str, ...],
    binary_app: Path | None = None,
    args_gn: Path | None = None,
) -> dict[str, object]:
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
    if (binary_app is None) != (args_gn is None):
        raise ManifestError("--binary-app and --args-gn must be supplied together")
    binary_binding = (
        bind_built_candidate(binary_app, args_gn)
        if binary_app is not None and args_gn is not None
        else None
    )
    return {
        "schemaVersion": 1,
        "sourceMode": "owned-macos-packaging-port",
        "binaryBindingStatus": (
            binary_binding["status"] if binary_binding else "pending-new-build"
        ),
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
        **({"binaryBinding": binary_binding} if binary_binding else {}),
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
    parser.add_argument(
        "--binary-app",
        type=Path,
        help="Absolute unsigned .app candidate to bind to the source evidence.",
    )
    parser.add_argument(
        "--args-gn",
        type=Path,
        help="Absolute args.gn used for the candidate build.",
    )
    args = parser.parse_args()
    try:
        root = args.source_root.resolve()
        output = args.output.resolve()
        if not output.is_absolute():
            raise ManifestError("output must be absolute")
        prefixes = tuple(safe_relative(value.rstrip("/")) for value in args.exclude_prefix)
        manifest = build_manifest(root, prefixes, args.binary_app, args.args_gn)
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
    print(f"Binary binding: {manifest['binaryBindingStatus']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
