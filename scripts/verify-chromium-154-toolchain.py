#!/usr/bin/env python3
"""Fail-closed identity check for the diagnostic Chromium M154 system Xcode."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCK = ROOT / "runtime" / "chromium-154-toolchain-lock.json"
def _run(args: list[str], *, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(args, check=True, capture_output=True, text=True, env=env)
    return (result.stdout + result.stderr).strip()


def probe_toolchain(expected_developer_dir: str) -> dict[str, str]:
    """Read the locked Xcode identity without changing global selection."""
    developer_dir = os.environ.get("DEVELOPER_DIR", "")
    if developer_dir != expected_developer_dir:
        raise ValueError("process-scoped DEVELOPER_DIR does not select the Xcode in the supplied lock")

    xcode_text = _run(["xcodebuild", "-version"])
    version_match = re.search(r"(?m)^Xcode\s+(.+)$", xcode_text)
    build_match = re.search(r"(?m)^Build version\s+(.+)$", xcode_text)
    if not version_match or not build_match:
        raise ValueError("xcodebuild did not report parseable version and build identifiers")

    sdk_version = _run(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    sdk_path = _run(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    sdk_build_path = Path(sdk_path) / "System/Library/CoreServices/SystemVersion.plist"
    with sdk_build_path.open("rb") as stream:
        sdk_build = str(plistlib.load(stream).get("ProductBuildVersion", ""))

    clang_text = _run(["xcrun", "clang", "--version"])
    clang_match = re.search(r"(?m)^Apple clang version .+$", clang_text)
    metal_text = _run(["xcrun", "metal", "-v"])
    metal_match = re.search(r"(?m)^Apple metal version .+$", metal_text)
    metal_build_match = re.search(r"metalfe-([0-9.]+)\)", metal_text)
    if not clang_match or not metal_match or not metal_build_match:
        raise ValueError("clang or Metal did not report parseable version identifiers")

    return {
        "xcodeVersion": version_match.group(1),
        "xcodeBuild": build_match.group(1),
        "sdkVersion": sdk_version,
        "sdkBuild": sdk_build,
        "clangVersion": clang_match.group(0),
        "metalVersion": metal_match.group(0),
        "metalBuild": metal_build_match.group(1),
    }


def _gn_check(text: str | None) -> tuple[bool, str]:
    if text is None:
        return False, "args.gn was not supplied; use_system_xcode was not verified"
    values = re.findall(r"(?m)^\s*use_system_xcode\s*=\s*(true|false)\s*(?:#.*)?$", text)
    if len(values) != 1 or values[0] != "true":
        return False, "args.gn must contain exactly one use_system_xcode = true setting"
    return True, "args.gn enables use_system_xcode exactly once"


def verify(lock: dict[str, Any], observed: dict[str, str], developer_dir: str,
           args_gn_text: str | None) -> dict[str, Any]:
    expected = lock["toolchain"]
    mismatches = []
    if developer_dir != expected["developerDirectory"]:
        mismatches.append("process-scoped DEVELOPER_DIR mismatch")
    for key in ("xcodeVersion", "xcodeBuild", "sdkVersion", "sdkBuild", "clangVersion", "metalVersion", "metalBuild"):
        if observed.get(key) != expected[key]:
            mismatches.append(f"{key} mismatch")
    gn_ok, gn_message = _gn_check(args_gn_text)
    if not gn_ok:
        mismatches.append(gn_message)

    return {
        "schemaVersion": 1,
        "check": "chromium-154-system-xcode-identity",
        "chromiumVersion": lock["chromiumVersion"],
        "verified": not mismatches,
        "releaseQualified": False,
        "systemXcode": True,
        "hermetic": False,
        "identity": {
            "developerDirectory": "/".join(Path(expected["developerDirectory"]).parts[-3:]) if developer_dir == expected["developerDirectory"] else "mismatch",
            **observed,
            "gnSystemXcode": gn_ok,
        },
        "message": gn_message,
        "mismatches": mismatches,
        "limitations": [
            "Identity verification is not a build, runtime, security, signing, notarization, or release qualification.",
            "Release qualification remains false until exact source replay and all fresh required gates pass.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--args-gn", type=Path, help="optional generated args.gn to check")
    parser.add_argument("--report", type=Path, help="optional JSON report destination")
    args = parser.parse_args()

    try:
        lock = json.loads(args.lock.read_text())
        args_gn_text = args.args_gn.read_text() if args.args_gn else None
        observed = probe_toolchain(lock["toolchain"]["developerDirectory"])
        report = verify(lock, observed, os.environ.get("DEVELOPER_DIR", ""), args_gn_text)
    except (OSError, ValueError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        # Do not echo subprocess output: it may contain host paths or credentials.
        report = {
            "schemaVersion": 1,
            "check": "chromium-154-system-xcode-identity",
            "verified": False,
            "releaseQualified": False,
            "systemXcode": True,
            "hermetic": False,
            "mismatches": [f"toolchain probe failed ({type(exc).__name__})"],
            "limitations": ["No build or release qualification is implied."],
        }
    serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.write_text(serialized)
    print(serialized, end="")
    return 0 if report["verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
