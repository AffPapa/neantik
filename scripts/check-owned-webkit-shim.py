#!/usr/bin/env python3
"""Verify the owned WebRTC shim against the pinned WebKit source, without editing it."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
UPSTREAM_COMMIT = "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
SOURCE_REL = pathlib.Path("Source/ThirdParty/libwebrtc/cmake/usage_exit_stub.c")
SOURCE_SHA = "c367aa9da488ee31442eb1766e41bfa1ee31abc142b7c0d379da1ffe1bd0edb6"
OWNED_SOURCE = ROOT / "Experiments/WebKitIsolation/owned-source/usage_exit_stub.c"
PATCH = ROOT / "Experiments/WebKitIsolation/owned-patches/usage-exit-stub-owned-source.patch"
OWNED_SOURCE_SHA = "d0aaaf82040011e5b4da3ddbbe9782db990381b2986c81b0cf283d64de0cae01"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(argv: list[str]) -> str:
    return subprocess.check_output(argv, text=True).strip()


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=pathlib.Path, required=True)
    args = parser.parse_args()
    source_root = args.source_root.resolve(strict=True)
    commit = run(["git", "-C", str(source_root), "rev-parse", "HEAD"])
    source_path = source_root / SOURCE_REL
    original = source_path.read_bytes()
    owned = OWNED_SOURCE.read_bytes()
    if commit != UPSTREAM_COMMIT:
        raise SystemExit(f"refusing source commit {commit}; expected pinned commit")
    if sha256(original) not in (SOURCE_SHA, OWNED_SOURCE_SHA):
        raise SystemExit("refusing unexpected shim bytes; neither pristine nor owned replacement")
    source_mode = "owned replacement already applied" if sha256(original) == OWNED_SOURCE_SHA else "pinned upstream original; patch not applied"
    if b"cmake/usage_exit_stub.c" not in (
        source_root / "Source/ThirdParty/libwebrtc/CMakeLists.txt"
    ).read_bytes():
        raise SystemExit("refusing: pinned CMake target no longer includes the shim")
    if b"SPDX-License-Identifier: MPL-2.0" not in owned or b"abort();" not in owned:
        raise SystemExit("owned shim lost its license marker or fail-stop behavior")
    if not PATCH.is_file():
        raise SystemExit("owned source patch is missing")

    compiler = run(["xcrun", "--find", "clang"])
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    with tempfile.TemporaryDirectory(prefix="neantik-owned-shim-") as directory:
        obj = pathlib.Path(directory) / "usage_exit_stub.o"
        subprocess.run([compiler, "-isysroot", sdk, "-Wall", "-Wextra", "-Werror", "-c", str(OWNED_SOURCE), "-o", str(obj)], check=True)
        symbols = run(["xcrun", "nm", "-g", str(obj)])
        if "_usage_exit" not in symbols:
            raise SystemExit("compiled object does not export usage_exit")
        result = {
            "status": "owned-shim-compile-pass",
            "upstreamCommit": commit,
            "currentSourceSHA256": sha256(original),
            "sourceMode": source_mode,
            "ownedSourceSHA256": sha256(owned),
            "patchSHA256": sha256(PATCH.read_bytes()),
            "compiledSymbol": "_usage_exit",
            "pinnedCheckoutSourceModified": source_mode == "owned replacement already applied",
            "runtimeLinkQualification": "see exact build receipt",
        }
        print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
