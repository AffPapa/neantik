#!/usr/bin/env python3

"""Apply NeAntik's deterministic fingerprint-hash overlay."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import sys


FILES = {
    "third_party/blink/renderer/core/dom/document.cc": {
        "before": "63e7818c26c66f812b04e9211161d9bb7974c2b3a29d02d8131f76667f641953",
        "after": "b432da2a42a837b3a4db825fc32775835d16bee19303ba1184f8cd7c956705c2",
        "replacements": 2,
    },
    "third_party/blink/renderer/modules/webaudio/offline_audio_context.cc": {
        "before": "ab66d6f545adcba3d02c4509279b2cada4774769006f142bf01e4f6a2092d004",
        "after": "176d9108f1bfa1255e0923852f869b5093d7933e41149d50e5a7848c31a8d5a8",
        "replacements": 2,
    },
    "third_party/blink/renderer/platform/fonts/font_cache.cc": {
        "before": "7af04e7eb86cad4751963f0b99cd2bd9fd50d4144414a4db62ca108a0159e1ad",
        "after": "9af47ff6467643f5491f8189b573a92ea1a6e7d382364c58a6b73ac0ff63b125",
        "replacements": 1,
    },
    "third_party/blink/renderer/platform/graphics/static_bitmap_image.cc": {
        "before": "eb2f7595b5e2140c69eeb205db3b0385175b77c55223ed47eb41316d87d94ed5",
        "after": "dc9c19a2d53ad83ba689914db6b35f18a6adaf455e5af3bed643b61620cb10e8",
        "replacements": 16,
    },
    "third_party/blink/renderer/modules/canvas/canvas2d/base_rendering_context_2d.cc": {
        "before": "6d3b980a942a75340d89c463036083899eaaf6182451f57f58f4984a22a47c4a",
        "after": "c1a8c2643b004dd001edda6d6008de09e5be0f1a436c9de8dd482f1622e3cc1d",
        "replacements": 1,
    },
}

COMMAND_LINE_INCLUDE = '#include "base/command_line.h"\n'
HASH_INCLUDE = '#include "base/hash/hash.h"\n'
UNSTABLE_HASH = "std::hash<std::string>{}"
STABLE_HASH = "base::PersistentHash"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def transform(data: bytes, replacements: int) -> bytes:
    text = data.decode("utf-8")
    if text.count(COMMAND_LINE_INCLUDE) != 1:
        raise ValueError("expected one base/command_line.h include")
    if HASH_INCLUDE in text:
        raise ValueError("base/hash/hash.h is already present in preimage")
    if text.count(UNSTABLE_HASH) != replacements:
        raise ValueError(
            f"expected {replacements} std::hash expressions"
        )
    text = text.replace(
        COMMAND_LINE_INCLUDE,
        COMMAND_LINE_INCLUDE + HASH_INCLUDE,
        1,
    )
    text = text.replace(UNSTABLE_HASH, STABLE_HASH)
    return text.encode("utf-8")


def replace_atomically(path: Path, data: bytes) -> None:
    temporary = path.with_name(f".{path.name}.nevision-overlay")
    temporary.write_bytes(data)
    os.chmod(temporary, path.stat().st_mode)
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()

    for relative, expectation in FILES.items():
        path = root / relative
        if not path.is_file():
            print(f"Missing Chromium source file: {path}", file=sys.stderr)
            return 66
        original = path.read_bytes()
        actual = digest(original)
        if actual == expectation["after"]:
            print(f"OK   {relative}")
            continue
        if actual != expectation["before"]:
            print(
                f"Unexpected preimage for {relative}: {actual}",
                file=sys.stderr,
            )
            return 65
        if arguments.check:
            print(f"Overlay is not applied: {relative}", file=sys.stderr)
            return 65
        try:
            updated = transform(original, expectation["replacements"])
        except ValueError as error:
            print(f"Cannot transform {relative}: {error}", file=sys.stderr)
            return 65
        updated_digest = digest(updated)
        if updated_digest != expectation["after"]:
            print(
                f"Unexpected postimage for {relative}: {updated_digest}",
                file=sys.stderr,
            )
            return 65
        replace_atomically(path, updated)
        print(f"APPLY {relative}")

    print(
        "NeAntik runtime overlay verified: "
        "all fingerprint hashes use base::PersistentHash."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
