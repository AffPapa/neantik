#!/usr/bin/env python3
"""Verify v20 linked-image header notices against a retained WebKit source tree."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "docs/evidence/third-party/webkit-v20-linked-image-source-headers/MANIFEST.json"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def comment_prefix(text: str) -> str:
    text = text.lstrip("\ufeff \t\r\n")
    position = 0
    end = 0
    while True:
        while position < len(text) and text[position].isspace():
            position += 1
        if text.startswith("/*", position):
            stop = text.find("*/", position + 2)
            if stop < 0:
                raise ValueError("unterminated source header")
            position = stop + 2
            end = position
        elif text.startswith("//", position):
            stop = text.find("\n", position)
            position = len(text) if stop < 0 else stop + 1
            end = position
        else:
            break
    return text[:end].rstrip() + "\n"


def verify(manifest_path: Path, source_tree: Path) -> dict[str, int]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or len(manifest.get("images", [])) != 3:
        raise ValueError("unexpected manifest scope")
    checked = 0
    for image in manifest["images"]:
        entries = image["entries"]
        if len(entries) != image["noticeEntryCount"]:
            raise ValueError("notice entry count mismatch")
        chunks = []
        for row in entries:
            rel = Path(row["sourcePath"])
            if (rel.is_absolute() or ".." in rel.parts or rel.parts[0] != "Source"):
                raise ValueError(f"unsafe source path: {rel}")
            path = source_tree / rel
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"missing physical source: {rel}")
            source = path.read_bytes()
            if digest(source) != row["sourceSHA256"]:
                raise ValueError(f"source hash mismatch: {rel}")
            header = comment_prefix(source.decode("utf-8")).encode("utf-8")
            if len(header) != row["headerBytes"] or digest(header) != row["headerSHA256"]:
                raise ValueError(f"source header mismatch: {rel}")
            chunks.extend((f"===== {rel.as_posix()} =====\n".encode(), header, b"\n"))
            checked += 1
        notice = b"".join(chunks)
        actual = manifest_path.parent / image["noticePath"]
        if (actual.is_symlink() or not actual.is_file()
                or len(notice) != image["noticeBytes"]
                or digest(notice) != image["noticeSHA256"]
                or actual.read_bytes() != notice):
            raise ValueError(f"assembled notice differs: {image['noticePath']}")
    return {"images": 3, "sourceHeaders": checked}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-tree", required=True, type=Path)
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.manifest, args.source_tree), sort_keys=True))


if __name__ == "__main__":
    main()
