#!/usr/bin/env python3
"""Verify an app's sealed SiteProtection resources match its source manager pin."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import sys


class VerificationError(ValueError):
    pass


def files_under(root: Path) -> dict[str, Path]:
    if root.is_symlink() or not root.is_dir():
        raise VerificationError("resource path is not a physical directory")
    result: dict[str, Path] = {}
    for path in root.rglob("*"):
        rel = path.relative_to(root).as_posix()
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise VerificationError(f"unsupported resource entry: {rel}")
        if stat.S_ISREG(info.st_mode):
            result[rel] = path
    return result


def verify(project_root: Path, app: Path) -> dict[str, object]:
    source_files = files_under(project_root / "Resources/SiteProtection")
    packaged_files = files_under(app / "Contents/Resources/SiteProtection")
    if set(source_files) != set(packaged_files):
        raise VerificationError("packaged resource inventory differs from source")
    seal_path = source_files.get("seal.json")
    if seal_path is None:
        raise VerificationError("source seal is missing")
    seal_bytes = seal_path.read_bytes()
    try:
        seal = json.loads(seal_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise VerificationError("source seal is invalid JSON") from error
    swift = project_root / "Sources/NeAntik/SiteProtectionBundle.swift"
    match = re.search(r'static let sealSHA256 = "([0-9a-f]{64})"', swift.read_text(encoding="utf-8"))
    digest = hashlib.sha256(seal_bytes).hexdigest()
    if match is None or match.group(1) != digest:
        raise VerificationError("source seal does not match manager pin")
    expected = seal.get("files")
    if not isinstance(expected, dict) or set(expected) != set(source_files) - {"seal.json"}:
        raise VerificationError("seal payload inventory differs from source")
    for name, expected_hash in expected.items():
        source_bytes = source_files[name].read_bytes()
        packaged_bytes = packaged_files[name].read_bytes()
        if not isinstance(expected_hash, str) or hashlib.sha256(source_bytes).hexdigest() != expected_hash:
            raise VerificationError(f"source payload does not match seal: {name}")
        if source_bytes != packaged_bytes:
            raise VerificationError(f"packaged payload differs from source: {name}")
    if packaged_files["seal.json"].read_bytes() != seal_bytes:
        raise VerificationError("packaged seal differs from source")
    return {"status": "PASS", "sealSHA256": digest, "payloadFiles": len(expected)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        print(json.dumps(verify(args.project_root, args.app), sort_keys=True))
        return 0
    except (OSError, VerificationError) as error:
        print(f"SiteProtection package verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
