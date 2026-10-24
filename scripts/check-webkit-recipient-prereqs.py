#!/usr/bin/env python3
"""Read-only preflight for a recipient's pinned WebKit source/relink inputs.

This checks inputs, tools, and an optional recipient identity. It never builds,
signs, launches, extracts, patches, or qualifies a corresponding-source offer.
The hashes describe the private v16 draft, not a future production release.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess


WEBKIT_COMMIT = "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
EXPECTED = {
    "webkitArchive": "5283e980fb4a691d9cc1bd05a0fa046a88c0d924c892259c7475311e828885dc",
    "neantikArchive": "cac6b7ee7c2a967a19cd78231d60f7cdf46289fad7ef0bfb2dea9161eb40801f",
    "patch": "ca3586d580610f91ee51bbebec42f558b181839bd866456a2084b98b811a6371",
    "buildConfig": "f498447afb0e9e2e48fffa4c9a795577dfcc3a74f812c70ecbb87d95ba174749",
}
PIN_KEYS = frozenset(EXPECTED)
PUBLISHER_TEAM = "H6VGU2M6JD"
SOURCE_MARKERS = ("Source/WebCore", "Source/JavaScriptCore", "Tools/Scripts/build-webkit")
TOOLS = ("cmake", "ninja", "zstd", "git", "tar", "python3", "xcodebuild", "xcrun", "codesign", "security")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_input_manifest(path: Path | None) -> tuple[str, dict[str, str], str | None]:
    """Select exact input hashes; never turn a manifest into a qualification."""
    if path is None:
        return WEBKIT_COMMIT, EXPECTED, None
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16_384:
        raise ValueError("Invalid pinned input manifest")
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
    except (OSError, ValueError, UnicodeDecodeError) as error:
        raise ValueError("Invalid pinned input manifest") from error
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "pinnedWebKitCommit", "expectedSHA256"}:
        raise ValueError("Invalid pinned input manifest")
    commit, hashes = value["pinnedWebKitCommit"], value["expectedSHA256"]
    if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or not isinstance(commit, str)
            or not re.fullmatch(r"[0-9a-f]{40}", commit)
            or not isinstance(hashes, dict) or set(hashes) != PIN_KEYS
            or any(not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
                   for digest in hashes.values())):
        raise ValueError("Invalid pinned input manifest")
    return commit, hashes, hashlib.sha256(raw).hexdigest()


def run_readonly(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True, check=False, timeout=15)


def check_pinned_file(path: Path | None, label: str, expected_sha: str) -> dict[str, object]:
    argument = {"webkitArchive": "--webkit-archive", "neantikArchive": "--neantik-archive",
                "patch": "--patch", "buildConfig": "--build-config"}[label]
    if path is None:
        return {"status": "missing", "reason": f"Supply {argument}"}
    if path.is_symlink() or not path.is_file():
        return {"status": "missing", "reason": "Expected a regular, non-symlink file"}
    try:
        actual = file_sha256(path)
    except OSError:
        return {"status": "unavailable", "reason": "Cannot read file"}
    return {"status": "pass" if actual == expected_sha else "mismatch", "sha256": actual}


def check_source_tree(path: Path | None) -> dict[str, object]:
    if path is None:
        return {"status": "missing", "reason": "Supply --source-tree after extracting the pinned archive"}
    if path.is_symlink() or not path.is_dir():
        return {"status": "missing", "reason": "Expected a physical extracted source directory"}
    absent = [marker for marker in SOURCE_MARKERS if not (path / marker).exists()]
    return {"status": "missing", "reason": "Required source markers absent", "markers": absent} if absent else {"status": "pass"}


def check_frameworks(path: Path | None) -> dict[str, object]:
    if path is None:
        return {"status": "missing", "reason": "Supply --built-frameworks after the recipient build"}
    if path.is_symlink() or not path.is_dir():
        return {"status": "missing", "reason": "Expected a physical Frameworks directory"}
    image = path / "WebKit.framework/Versions/A/WebKit"
    xpc = path / "WebKit.framework/Versions/A/XPCServices"
    absent = [name for name, entry in (("WebKit image", image), ("XPCServices", xpc)) if not entry.exists()]
    return {"status": "missing", "reason": "Built runtime layout incomplete", "components": absent} if absent else {"status": "pass", "note": "Layout only; images and signatures unverified"}


def check_manager(path: Path | None, team: str | None) -> dict[str, object]:
    if path is None:
        return {"status": "missing", "reason": "Supply --manager-app signed by the recipient team"}
    if path.is_symlink() or not path.is_dir() or path.suffix != ".app":
        return {"status": "missing", "reason": "Expected a physical .app directory"}
    info_path = path / "Contents/Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException):
        return {"status": "missing", "reason": "Manager Info.plist unavailable"}
    if not isinstance(info, dict) or not info.get("CFBundleIdentifier"):
        return {"status": "mismatch", "reason": "Manager bundle identifier missing"}
    try:
        result = run_readonly(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)])
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "unavailable", "reason": "Manager signature metadata could not be read"}
    match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", result.stderr, re.MULTILINE)
    if result.returncode or match is None:
        return {"status": "unavailable", "reason": "Manager signed team could not be established"}
    if team and match.group(1) != team:
        return {"status": "mismatch", "reason": "Manager team differs from requested recipient team"}
    return {"status": "pass", "team": match.group(1), "note": "Metadata only; package verifier still required"}


def check_identity(sha1: str | None, team: str | None) -> dict[str, object]:
    if sha1 is None:
        return {"status": "missing", "reason": "Supply --identity-sha1 for a recipient-owned Developer ID Application identity"}
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", sha1):
        return {"status": "mismatch", "reason": "Identity must be a 40-character certificate SHA-1"}
    try:
        result = run_readonly(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "unavailable", "reason": "Signing identity list unavailable"}
    if result.returncode:
        return {"status": "unavailable", "reason": "Signing identity list unavailable"}
    for line in result.stdout.splitlines():
        match = re.search(r'\b([0-9A-Fa-f]{40})\b\s+"Developer ID Application:[^"\n]*\(([A-Z0-9]{10})\)"', line)
        if match and match.group(1).lower() == sha1.lower():
            if team and match.group(2) != team:
                return {"status": "mismatch", "reason": "Identity team differs from requested recipient team"}
            return {"status": "pass", "team": match.group(2), "note": "Local identity visible; ownership and signing remain unproved"}
    return {"status": "missing", "reason": "Requested Developer ID Application identity unavailable"}


def check_toolchain() -> dict[str, object]:
    absent = [tool for tool in TOOLS if shutil.which(tool) is None]
    result: dict[str, object] = {"status": "missing" if absent else "pass", "missingTools": absent}
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        result["status"] = "mismatch"
        result["reason"] = "Observed candidate required macOS arm64"
        return result
    try:
        sdk = run_readonly(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"])
        xcode = run_readonly(["/usr/bin/xcodebuild", "-version"])
    except (OSError, subprocess.TimeoutExpired):
        result["status"] = "unavailable"
        result["reason"] = "Xcode or SDK version could not be read"
        return result
    if sdk.returncode or xcode.returncode:
        result["status"] = "unavailable"
        result["reason"] = "Xcode or SDK version could not be read"
    elif sdk.stdout.strip() != "27.0" or not xcode.stdout.startswith("Xcode 27.0\n"):
        result["status"] = "mismatch"
        result["reason"] = "Observed candidate used Xcode 27.0 and macOS SDK 27.0"
    return result


def inspect(args: argparse.Namespace) -> dict[str, object]:
    webkit_commit, expected, manifest_sha = load_input_manifest(getattr(args, "input_manifest", None))
    team = args.recipient_team
    team_status = "pass" if team and re.fullmatch(r"[A-Z0-9]{10}", team) and team != PUBLISHER_TEAM else "missing" if not team else "mismatch"
    checks = {
        "recipientTeam": {"status": team_status, "reason": "Independent recipient team required" if team_status != "pass" else ""},
        "webkitArchive": check_pinned_file(args.webkit_archive, "webkitArchive", expected["webkitArchive"]),
        "neantikArchive": check_pinned_file(args.neantik_archive, "neantikArchive", expected["neantikArchive"]),
        "patch": check_pinned_file(args.patch, "patch", expected["patch"]),
        "buildConfig": check_pinned_file(args.build_config, "buildConfig", expected["buildConfig"]),
        "sourceTree": check_source_tree(args.source_tree),
        "toolchain": check_toolchain(),
        "builtFrameworks": check_frameworks(args.built_frameworks),
        "managerApp": check_manager(args.manager_app, team),
        "identity": check_identity(args.identity_sha1, team),
        "completeDependencyInputs": {"status": "unresolved", "reason":
                                     "The private v16 draft lacks a reviewed exact transitive dependency/source and full build recipe"},
    }
    pinned_ready = all(checks[name]["status"] == "pass" for name in
                       ("webkitArchive", "neantikArchive", "patch", "buildConfig", "sourceTree", "toolchain"))
    recipient_inputs_present = pinned_ready and all(checks[name]["status"] == "pass" for name in
                                                    ("recipientTeam", "builtFrameworks", "managerApp", "identity"))
    return {
        "schemaVersion": 1,
        "mode": "read-only-prerequisite-check",
        "pinnedWebKitCommit": webkit_commit,
        "inputManifestSHA256": manifest_sha,
        "checks": checks,
        "knownPinnedInputsPresent": pinned_ready,
        "recipientPackagingInputsPresent": recipient_inputs_present,
        "completeBuildInputsEstablished": False,
        "recipientRelinkProved": False,
        "licenseOrSourceOfferQualified": False,
        "remainingProof": ["recipient-controlled source edit and dependent rebuild",
                           "exact nested-runtime signatures and mixed-team rejection",
                           "headed proof of the modified loaded image",
                           "reviewed licenses, notices and final binary/source binding"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--webkit-archive", type=Path)
    parser.add_argument("--input-manifest", type=Path, help="optional exact-hash manifest for a new private source draft")
    parser.add_argument("--neantik-archive", type=Path)
    parser.add_argument("--patch", type=Path)
    parser.add_argument("--build-config", type=Path)
    parser.add_argument("--source-tree", type=Path)
    parser.add_argument("--built-frameworks", type=Path)
    parser.add_argument("--manager-app", type=Path)
    parser.add_argument("--recipient-team")
    parser.add_argument("--identity-sha1")
    try:
        report = inspect(parser.parse_args())
    except (OSError, ValueError):
        parser.exit(2, "Pinned input manifest refused.\n")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0 if report["recipientPackagingInputsPresent"] and report["completeBuildInputsEstablished"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
