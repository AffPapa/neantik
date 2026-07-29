#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RELEASE_METADATA = PROJECT_ROOT / "releases" / "v0.3.12.json"

FORBIDDEN_PARTS = {
    ".build",
    ".swiftpm",
    "DerivedData",
    "dist",
    "node_modules",
    "__pycache__",
}
FORBIDDEN_SUFFIXES = {
    ".p12",
    ".pem",
    ".key",
    ".mobileprovision",
    ".pyc",
}
FORBIDDEN_NAMES = {
    ".DS_Store",
    ".env",
}
FORBIDDEN_TEXT = {
    "/Users/dumay": "personal absolute path",
    "root@135.181.253.143": "private deployment endpoint",
    "/Users/dumay/AFF.job/.secrets": "private secret-store path",
}
SECRET_PATTERNS = {
    "private key": re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    "GitHub token": re.compile(r"\bgh[opsu]_[A-Za-z0-9_]{20,}\b"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
}
TEXT_SUFFIXES = {
    "",
    ".command",
    ".css",
    ".html",
    ".json",
    ".md",
    ".mjs",
    ".plist",
    ".py",
    ".sh",
    ".swift",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".yml",
    ".yaml",
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def iter_public_files() -> list[Path]:
    files: list[Path] = []
    for path in PROJECT_ROOT.rglob("*"):
        relative = path.relative_to(PROJECT_ROOT)
        if ".git" in relative.parts:
            continue
        if any(part in FORBIDDEN_PARTS for part in relative.parts):
            fail(f"forbidden generated path is present: {relative}")
        if path.is_file():
            files.append(path)
    return files


def verify_files(files: list[Path]) -> None:
    for path in files:
        relative = path.relative_to(PROJECT_ROOT)
        if path.resolve() == Path(__file__).resolve():
            continue
        if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            fail(f"forbidden file is present: {relative}")
        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for needle, description in FORBIDDEN_TEXT.items():
            if needle in text:
                fail(f"{description} found in {relative}")
        for description, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                fail(f"possible {description} found in {relative}")


def verify_release_metadata() -> None:
    metadata = json.loads(RELEASE_METADATA.read_text(encoding="utf-8"))
    archive = metadata["archive"]
    sidecar = PROJECT_ROOT / "releases" / f"{archive['name']}.sha256"
    expected = f"{archive['sha256']}  {archive['name']}\n"
    if sidecar.read_text(encoding="utf-8") != expected:
        fail("release checksum sidecar does not match releases/v0.3.12.json")

    plist = PROJECT_ROOT / "Resources" / "Info.plist"
    plist_text = plist.read_text(encoding="utf-8")
    if f"<string>{metadata['version']}</string>" not in plist_text:
        fail("release version does not match Resources/Info.plist")
    if f"<string>{metadata['build']}</string>" not in plist_text:
        fail("release build does not match Resources/Info.plist")


def main() -> None:
    files = iter_public_files()
    verify_files(files)
    verify_release_metadata()
    print(
        "PASS: open-source tree contains no generated build roots, "
        "private deployment paths, or recognized secret material; "
        f"{len(files)} file(s) checked."
    )


if __name__ == "__main__":
    main()
