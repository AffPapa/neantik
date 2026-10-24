#!/usr/bin/env python3
"""Compare one frozen NeAntik ZIP's owned WebKit files with a pinned inventory.

This is a byte/change queue for release review, not a license decision or a
runtime qualification. It reads ZIP members without extracting or executing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import stat
import sys
import zipfile


FRAMEWORK_PREFIX = (
    "NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/"
    "Contents/Frameworks/"
)
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}


class InventoryError(ValueError):
    pass


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _baseline(path: Path) -> tuple[str, dict[str, dict[str, object]]]:
    if path.is_symlink() or not path.is_file():
        raise InventoryError("baseline must be a physical JSON file")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1 or not isinstance(data.get("candidateSHA256"), str):
        raise InventoryError("unsupported baseline inventory")
    scope = data.get("scopes", {}).get("ownedWebKitFrameworks", {})
    rows = scope.get("entries")
    if not isinstance(rows, list) or len(rows) != scope.get("entryCount"):
        raise InventoryError("baseline entry count does not match")
    result: dict[str, dict[str, object]] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            raise InventoryError("invalid baseline entry")
        name = row["path"]
        if name in result or name.startswith("/") or ".." in name.split("/"):
            raise InventoryError("duplicate or unsafe baseline path")
        if row.get("kind") == "symlink":
            if not isinstance(row.get("target"), str):
                raise InventoryError("invalid baseline symlink")
        elif row.get("kind") in {"Mach-O", "resource-or-metadata"}:
            if not isinstance(row.get("sha256"), str) or not isinstance(row.get("bytes"), int):
                raise InventoryError("invalid baseline regular file")
        else:
            raise InventoryError("invalid baseline kind")
        result[name] = row
    return data["candidateSHA256"], result


def _entry(archive: zipfile.ZipFile, member: zipfile.ZipInfo) -> dict[str, object]:
    mode = stat.S_IFMT(member.external_attr >> 16)
    if mode == stat.S_IFLNK:
        if member.file_size > 4096:
            raise InventoryError("oversized symlink target")
        target = archive.read(member).decode("utf-8")
        if not target or target.startswith("/") or ".." in target.split("/"):
            raise InventoryError("unsafe symlink target")
        return {"kind": "symlink", "target": target}
    if mode not in (0, stat.S_IFREG):
        raise InventoryError("unsupported Frameworks entry type")
    digest = hashlib.sha256()
    size = 0
    prefix = b""
    with archive.open(member) as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            if not prefix:
                prefix = chunk[:4]
            digest.update(chunk)
            size += len(chunk)
    if size != member.file_size:
        raise InventoryError("ZIP member size changed during read")
    return {"kind": "Mach-O" if prefix in MACHO_MAGICS else "resource-or-metadata",
            "bytes": size, "sha256": digest.hexdigest()}


def compare(archive_path: Path, baseline_path: Path, expected_sha256: str) -> dict[str, object]:
    if len(expected_sha256) != 64 or any(c not in "0123456789abcdef" for c in expected_sha256):
        raise InventoryError("expected archive SHA-256 must be lowercase hex")
    if archive_path.is_symlink() or not archive_path.is_file():
        raise InventoryError("archive must be a physical ZIP file")
    actual_sha = _hash_file(archive_path)
    if actual_sha != expected_sha256:
        raise InventoryError("archive SHA-256 mismatch")
    old_sha, old = _baseline(baseline_path)
    current: dict[str, dict[str, object]] = {}
    with zipfile.ZipFile(archive_path) as archive:
        members = archive.infolist()
        if len(members) > 30000:
            raise InventoryError("ZIP has too many members")
        for member in members:
            name = member.filename
            if not name.startswith(FRAMEWORK_PREFIX) or member.is_dir():
                continue
            relative = name[len(FRAMEWORK_PREFIX):]
            if (not relative or relative.startswith("/") or ".." in relative.split("/")
                    or "\\" in relative or relative in current):
                raise InventoryError("duplicate or unsafe Frameworks member")
            current[relative] = _entry(archive, member)
    if not current:
        raise InventoryError("owned WebKit Frameworks absent from ZIP")
    unchanged = sorted(name for name in old.keys() & current.keys() if old[name] == {"path": name, **current[name]})
    changed = sorted(name for name in old.keys() & current.keys() if name not in unchanged)
    added = sorted(current.keys() - old.keys())
    missing = sorted(old.keys() - current.keys())
    review = []
    for name in changed + added + missing:
        review.append({"path": name, "status": "changed" if name in changed else "added" if name in added else "missing",
                       "before": {key: value for key, value in old.get(name, {}).items() if key != "path"} or None,
                       "after": current.get(name)})
    return {"schemaVersion": 1, "mode": "byte-delta-only", "archiveSHA256": actual_sha,
            "baselineArchiveSHA256": old_sha, "counts": {"baseline": len(old), "candidate": len(current),
            "unchanged": len(unchanged), "changed": len(changed), "added": len(added), "missing": len(missing)},
            "reviewQueue": review,
            "qualification": "unproved; review licenses, source and notices separately"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--output", type=Path, help="write JSON receipt instead of printing it")
    args = parser.parse_args()
    try:
        report = compare(args.archive, args.baseline, args.archive_sha256)
    except (OSError, ValueError, zipfile.BadZipFile, UnicodeError) as error:
        print(f"Framework inventory refused: {error}", file=sys.stderr)
        return 2
    rendered = json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if args.output:
        if args.output.is_symlink():
            print("Framework inventory refused: output is a symlink", file=sys.stderr)
            return 2
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
