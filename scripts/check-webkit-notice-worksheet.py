#!/usr/bin/env python3
"""Compare the 100 mapped WebKit notice rows with one exact Frameworks tree.

This is a byte-binding aid for the release reviewer, not a license decision or
distribution approval. It never changes the worksheet or the app bundle.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat


HEX64 = re.compile(r"[0-9a-f]{64}\Z")
DECISION_FIELDS = ("applicableLicense", "noticeLocation", "requiredNotice", "reviewerDecision")


class WorksheetError(ValueError):
    pass


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            value.update(block)
    return value.hexdigest()


def physical_file(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or "\\" in relative or not relative:
        raise WorksheetError("unsafe runtime path")
    parts = PurePosixPath(relative)
    if parts.is_absolute() or any(part in ("", ".", "..") for part in relative.split("/")):
        raise WorksheetError("unsafe runtime path")
    current = root
    for part in parts.parts:
        current = current / part
        mode = current.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise WorksheetError("runtime path traverses a symlink")
    if not stat.S_ISREG(current.stat().st_mode):
        raise WorksheetError("runtime path is not a regular file")
    return current


def compare(worksheet: dict, frameworks: Path, *, complete: bool = True) -> dict:
    if not frameworks.is_dir() or frameworks.is_symlink():
        raise WorksheetError("Frameworks root must be a physical directory")
    if worksheet.get("schemaVersion") != 1:
        raise WorksheetError("unsupported worksheet schema")
    images, resources = worksheet.get("images"), worksheet.get("resources")
    if not isinstance(images, list) or not isinstance(resources, list):
        raise WorksheetError("worksheet rows missing")
    if complete and (len(images), len(resources)) != (16, 84):
        raise WorksheetError("expected 16 images and 84 resources")
    seen: set[str] = set()
    changed: list[dict] = []
    unresolved: list[str] = []
    for kind, rows in (("image", images), ("resource", resources)):
        for row in rows:
            if not isinstance(row, dict):
                raise WorksheetError("malformed worksheet row")
            relative, expected = row.get("runtimePath"), row.get("runtimeSHA256")
            if not isinstance(relative, str) or relative in seen:
                raise WorksheetError("duplicate or malformed runtime path")
            if not isinstance(expected, str) or not HEX64.fullmatch(expected):
                raise WorksheetError("invalid worksheet digest")
            seen.add(relative)
            actual = digest(physical_file(frameworks, relative))
            if actual != expected:
                changed.append({"kind": kind, "runtimePath": relative,
                                "worksheetSHA256": expected, "observedSHA256": actual})
            decision = row.get("decision")
            if not isinstance(decision, dict) or any(
                not isinstance(decision.get(field), str) or
                decision[field].strip().casefold() in ("", "unknown") for field in DECISION_FIELDS
            ):
                unresolved.append(relative)
    return {"schemaVersion": 1, "imageCount": len(images),
            "resourceCount": len(resources), "changedCount": len(changed),
            "changed": changed, "unresolvedDecisionCount": len(unresolved),
            "unresolvedDecisionPaths": unresolved,
            "interpretation": "Byte comparison only; legal applicability and recipient relink remain separate gates."}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worksheet", type=Path, required=True)
    parser.add_argument("--frameworks", type=Path, required=True)
    parser.add_argument("--strict", action="store_true",
                        help="fail if any byte differs or reviewer decision is unresolved")
    args = parser.parse_args()
    try:
        result = compare(json.loads(args.worksheet.read_text()), args.frameworks)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.exit(2, f"worksheet check failed: {error}\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    if args.strict and (result["changedCount"] or result["unresolvedDecisionCount"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
