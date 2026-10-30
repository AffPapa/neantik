#!/usr/bin/env python3
"""Restore exact build-only typings omitted by the filtered M155 Node artifact.

Uses a supplied official npm archive and the reviewed SHA-512/SHA-256 inventory.
No download, package installation, runtime qualification or dependency fallback.
"""
import argparse
import base64
import hashlib
import json
import tarfile
import tempfile
from pathlib import Path

from chromium_15540_release_evidence import safe_relative_regular, verify_restored_build_types
from runtime_locked_overlay import apply_overlay


def restore(source: Path, archive: Path, evidence: Path) -> None:
    report = json.loads(evidence.read_text())["restoredBuildTypes"]
    verify_restored_build_types(report)
    source = source.resolve(strict=True)
    package_lock = safe_relative_regular(source, "third_party/node/package-lock.json")
    if hashlib.sha256(package_lock.read_bytes()).hexdigest() != report["packageLockSHA256"]:
        raise ValueError("Node package-lock differs from reviewed M155 input")
    data = archive.read_bytes()
    if (hashlib.sha256(data).hexdigest() != report["archiveSHA256"]
            or "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode() != report["integrity"]):
        raise ValueError("Official package archive integrity mismatch")
    records = {item["path"]: item for item in report["files"]}
    with tempfile.TemporaryDirectory(prefix="neantik-pinned-build-types-") as temporary:
        payloads = Path(temporary)
        seen = set()
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar.getmembers():
                if not member.isfile() or not member.name.startswith("package/") or len(Path(member.name).parts) != 2:
                    raise ValueError("Unexpected package archive member")
                name = Path(member.name).name
                if name in seen:
                    raise ValueError("Duplicate package archive member")
                seen.add(name)
                payload = tar.extractfile(member).read()
                relative = "third_party/node/node_modules/undici-types/" + name
                if name in {"LICENSE", "package.json"}:
                    if safe_relative_regular(source, relative).read_bytes() != payload:
                        raise ValueError("Pinned Node metadata differs from archive")
                elif name == "README.md":
                    continue
                elif relative in records and hashlib.sha256(payload).hexdigest() == records[relative]["sha256"]:
                    target = payloads / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(payload)
                else:
                    raise ValueError("Archive contains unreviewed type bytes")
        apply_overlay(source, payloads, [dict(path=name, preimageSHA256=None,
                      postimageSHA256=item["sha256"]) for name, item in records.items()])
    verify_restored_build_types(report, source)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--evidence", type=Path, default=Path(__file__).resolve().parents[1] /
                        "runtime/chromium-15540-source-evidence/pinned-build-inputs.json")
    args = parser.parse_args()
    for path in (args.source_root, args.archive, args.evidence):
        if not path.is_absolute() or path.is_symlink():
            parser.error("Inputs must be absolute non-symlink paths")
    restore(args.source_root, args.archive, args.evidence)
    print("PASS: exact pinned build-only type files restored; runtime remains unqualified.")


if __name__ == "__main__":
    main()
