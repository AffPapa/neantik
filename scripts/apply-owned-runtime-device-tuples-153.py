#!/usr/bin/env python3
"""Apply and verify the reviewed Apple tuple layer for Chromium 153.0.8010.52.

This is deliberately separate from the historical Chromium 152 overlay. It
applies one exact patch against the 153 owned source base and locks every
generated postimage. It never rewrites a mismatched source with fuzzy context.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
STATUS_PATH = PROJECT_ROOT / "runtime" / "chromium-153-port-status.json"
PATCH_PATH = (
    PROJECT_ROOT
    / "runtime"
    / "nevision-patches"
    / "patches"
    / "canonical-apple-device-tuples-153.patch"
)
EXPECTED_VERSION = "153.0.8010.52"
EXPECTED_PATCH_SHA256 = (
    "93dd686b8b8e67cc6398da28c926e309d0fd20fa464d41345561f06242464ce1"
)
POSTIMAGE_SHA256 = {
    "components/embedder_support/BUILD.gn":
        "1c37df24e83fae9ae7a04c6e12ce830d54d01f5a2cdc045a960aaf3f7418ddac",
    "components/embedder_support/user_agent_utils.cc":
        "c3d97522a38a6e284901e712bd0401d02fe1b0775cdbeb992af16035baf63937",
    "components/ungoogled/neantik_apple_device_tuples.h":
        "3ef1b5bf96166edcde85177ba4ba14fac9aabf724cb8cb0e14c1076b0648214b",
    "third_party/blink/renderer/core/frame/local_dom_window.cc":
        "033c2a076a5d4225c6428fbca0bcd7f172c0acca2c0fb803e258c9e3b591613a",
    "third_party/blink/renderer/core/frame/navigator_concurrent_hardware.cc":
        "ebc2b259e2fc467733904e2eac27621a2e2cd0a415934f94ab1739ee27f0d5aa",
    "third_party/blink/renderer/core/frame/navigator_device_memory.cc":
        "c627f44995fb92e3db4ba43eb75bd91fd53defa8f59f8a18a0b9ce8153d38a8a",
    "third_party/blink/renderer/core/frame/screen.cc":
        "82efdc31e4bae7a895e53bc54f33dc1797fdd05361136430e0655c06fc7f8d48",
    "third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc":
        "34f4961cb49b1a7e0cacbd482c650e1f7f5b796cd232c5b1e0afcaeb71d9d584",
}


class OverlayError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(source_root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source_root), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise OverlayError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def load_status() -> dict[str, Any]:
    try:
        value = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise OverlayError(f"cannot read Chromium 153 status: {error}") from error
    if not isinstance(value, dict):
        raise OverlayError("Chromium 153 status must be an object")
    return value


def verify_source_identity(source_root: Path) -> None:
    status = load_status()
    if status.get("targetChromiumVersion") != EXPECTED_VERSION:
        raise OverlayError("Chromium 153 status target mismatch")
    official = status.get("officialChromiumBase")
    if not isinstance(official, dict):
        raise OverlayError("Chromium 153 status has no official source lock")
    if git(source_root, "rev-parse", "HEAD") != official.get("commit"):
        raise OverlayError("source HEAD does not match the Chromium 153 lock")
    if git(source_root, "rev-parse", "HEAD^{tree}") != official.get("tree"):
        raise OverlayError("source tree does not match the Chromium 153 lock")
    version_file = source_root / "chrome" / "VERSION"
    if not version_file.is_file():
        raise OverlayError("Chromium VERSION file is missing")
    fields = dict(
        line.split("=", 1)
        for line in version_file.read_text(encoding="utf-8").splitlines()
        if "=" in line
    )
    actual = ".".join(
        fields.get(key, "") for key in ("MAJOR", "MINOR", "BUILD", "PATCH")
    )
    if actual != EXPECTED_VERSION:
        raise OverlayError(f"source VERSION mismatch: {actual}")


def verify_postimages(source_root: Path) -> None:
    mismatches = []
    for relative, expected in POSTIMAGE_SHA256.items():
        path = source_root / relative
        if not path.is_file() or path.is_symlink():
            mismatches.append(f"{relative}: missing")
            continue
        actual = sha256(path)
        if actual != expected:
            mismatches.append(f"{relative}: {actual} != {expected}")
    if mismatches:
        raise OverlayError("canonical 153 tuple postimages are not verified:\n" + "\n".join(mismatches))


def apply(source_root: Path, check_only: bool) -> None:
    if not source_root.is_absolute() or not source_root.is_dir() or source_root.is_symlink():
        raise OverlayError("source root must be an absolute non-symlink directory")
    if not PATCH_PATH.is_file() or PATCH_PATH.is_symlink():
        raise OverlayError("canonical Chromium 153 tuple patch is missing")
    if sha256(PATCH_PATH) != EXPECTED_PATCH_SHA256:
        raise OverlayError("canonical Chromium 153 tuple patch SHA-256 mismatch")
    verify_source_identity(source_root)
    try:
        verify_postimages(source_root)
        print("Chromium 153 canonical Apple tuple overlay already verified.")
        return
    except OverlayError:
        if check_only:
            raise
    check = subprocess.run(
        ["git", "-C", str(source_root), "apply", "--check", str(PATCH_PATH)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if check.returncode:
        raise OverlayError(f"canonical 153 tuple patch does not apply:\n{check.stdout.strip()}")
    if check_only:
        raise OverlayError("canonical 153 tuple overlay is not applied")
    result = subprocess.run(
        ["git", "-C", str(source_root), "apply", "--binary", str(PATCH_PATH)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode:
        raise OverlayError(f"canonical 153 tuple patch failed:\n{result.stdout.strip()}")
    verify_postimages(source_root)
    print("Chromium 153 canonical Apple tuple overlay applied and verified.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        apply(args.source_root.resolve(), args.check)
    except (OSError, OverlayError) as error:
        print(f"Chromium 153 canonical tuple overlay failed: {error}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
