#!/usr/bin/env python3
"""Audit exact owned-WebKit Mach-O hashes and bundle-relative @rpath edges.

This is a static closure audit. It does not call dyld, launch an app, sign, or
qualify the declared minimum macOS version.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys


class AuditError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_rpath_edge(loader: Path, install_name: str, rpaths: list[str],
                       payload_root: Path, system_swift_root: Path) -> dict:
    loader = loader.resolve(strict=True)
    payload_root = payload_root.resolve(strict=True)
    system_swift_root = system_swift_root.resolve(strict=True)
    if not install_name.startswith("@rpath/"):
        raise AuditError("Only @rpath dependencies can be resolved by this helper")
    suffix = install_name.removeprefix("@rpath/")
    if not suffix or Path(suffix).is_absolute() or ".." in Path(suffix).parts:
        raise AuditError("Unsafe @rpath install name")

    candidates: set[Path] = set()
    for rpath in rpaths:
        if rpath == "/usr/lib/swift":
            candidates.add(system_swift_root / suffix)
        elif rpath.startswith("@loader_path"):
            relative = rpath.removeprefix("@loader_path").lstrip("/")
            candidates.add(loader.parent / relative / suffix)
        elif rpath.startswith("/"):
            candidates.add(Path(rpath) / suffix)

    resolved: set[Path] = set()
    alias_without_file: list[Path] = []
    for candidate in candidates:
        try:
            real = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            # Some macOS Swift compatibility paths are symlinks into dyld's
            # shared cache, not ordinary files. Preserve that distinction.
            if candidate.is_symlink():
                alias_without_file.append(candidate)
            continue
        if real.is_file():
            resolved.add(real)

    if len(resolved) == 1:
        target = next(iter(resolved))
        try:
            relative = target.relative_to(payload_root)
        except ValueError:
            return {"state": "external-file", "target": str(target)}
        return {"state": "payload-file", "target": relative.as_posix(),
                "sha256": sha256(target)}
    if len(resolved) > 1:
        return {"state": "ambiguous", "targets": sorted(str(path) for path in resolved)}
    if len(alias_without_file) == 1:
        alias = alias_without_file[0]
        return {"state": "system-alias-needs-dyld-verification",
                "alias": str(alias), "symlinkTarget": alias.readlink().as_posix(),
                "canonicalFilePresent": alias.exists()}
    return {"state": "unresolved", "candidateCount": len(candidates)}


def audit(load_receipt: dict, payload_root: Path,
          system_swift_root: Path = Path("/usr/lib/swift")) -> dict:
    root = payload_root.resolve(strict=True)
    images = load_receipt.get("images")
    if not isinstance(images, list) or not images:
        raise AuditError("Load-command receipt has no images")
    expected_hashes: set[str] = set()
    verified_images: list[str] = []
    for item in images:
        relative = Path(item["path"])
        expected = item["sha256"]
        if (relative.is_absolute() or ".." in relative.parts or len(expected) != 64
                or any(char not in "0123456789abcdef" for char in expected)):
            raise AuditError("Load receipt contains an unsafe path or digest")
        path = root / relative
        try:
            path.resolve(strict=True).relative_to(root)
            actual = sha256(path)
        except (OSError, ValueError, RuntimeError) as error:
            raise AuditError(f"Exact Mach-O image is missing or escapes payload: {relative}") from error
        if actual != expected:
            raise AuditError(f"Exact Mach-O image hash differs from receipt: {relative}")
        expected_hashes.add(expected)
        verified_images.append(relative.as_posix())

    bundled: list[dict] = []
    external: list[dict] = []
    for item in images:
        loader_rel = Path(item["path"])
        loader = root / loader_rel
        for dependency in item.get("dependencies", []):
            name = dependency.get("name", "")
            if not name.startswith("@rpath/"):
                continue
            edge = resolve_rpath_edge(loader, name, item.get("rpaths", []),
                                      root, system_swift_root)
            record = {"loader": loader_rel.as_posix(), "installName": name, **edge}
            if edge["state"] == "payload-file":
                if edge["sha256"] not in expected_hashes:
                    record["state"] = "payload-target-not-in-image-inventory"
                    external.append(record)
                else:
                    bundled.append(record)
            else:
                external.append(record)
    return {
        "expectedMachOImages": len(images),
        "verifiedMachOImages": len(verified_images),
        "bundleRelativeReferences": len(bundled) + len(external),
        "resolvedPayloadReferences": len(bundled),
        "distinctPayloadTargets": len({item["target"] for item in bundled}),
        "externalOrUnresolvedReferences": external,
        "allImageHashesMatchReceipt": len(images) == len(verified_images),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("load_receipt", type=Path)
    parser.add_argument("payload_root", type=Path)
    parser.add_argument("--system-swift-root", type=Path, default=Path("/usr/lib/swift"))
    args = parser.parse_args()
    try:
        report = audit(json.loads(args.load_receipt.read_text()), args.payload_root,
                       args.system_swift_root)
    except (OSError, json.JSONDecodeError, KeyError, TypeError, AuditError) as error:
        print(json.dumps({"status": "error", "error": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if not report["externalOrUnresolvedReferences"] else 2


if __name__ == "__main__":
    sys.exit(main())
