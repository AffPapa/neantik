#!/usr/bin/env python3
"""Run the release-facing runtime checks that are possible before signing.

The report intentionally describes an unsigned local candidate. It is useful
for the next release gate, but it can never be used as notarization, Gatekeeper
or publication evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
STATUS_PATH = PROJECT_ROOT / "runtime" / "chromium-153-port-status.json"


class RuntimeCandidateError(ValueError):
    pass


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeCandidateError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeCandidateError(f"{label} must be a JSON object")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], label: str) -> str:
    result = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode:
        raise RuntimeCandidateError(f"{label} failed:\n{result.stdout.strip()}")
    return result.stdout.strip()


def plist(path: Path, key: str) -> str:
    return run(["/usr/bin/plutil", "-extract", key, "raw", "-o", "-", str(path)], f"read {key}")


def verify_args(args_gn: Path) -> None:
    if not args_gn.is_absolute() or not args_gn.is_file() or args_gn.is_symlink():
        raise RuntimeCandidateError("args.gn must be an absolute regular file")
    text = args_gn.read_text(encoding="utf-8")
    if not re.search(r"(?m)^\s*target_cpu\s*=\s*\"arm64\"\s*$", text):
        raise RuntimeCandidateError("args.gn does not pin target_cpu=arm64")
    if not re.search(r"(?m)^\s*angle_enable_metal\s*=\s*true\s*$", text):
        raise RuntimeCandidateError("args.gn does not enable Metal")


def macho_files(app: Path) -> list[Path]:
    found: list[Path] = []
    for root, directories, files in os.walk(app / "Contents", followlinks=False):
        directories[:] = [name for name in directories if not (Path(root) / name).is_symlink()]
        for name in files:
            path = Path(root) / name
            if path.is_symlink() or not path.is_file():
                continue
            if ".app/Contents/" in str(path) and path.parent.name == "Resources":
                continue
            output = subprocess.run(
                ["/usr/bin/file", "-b", str(path)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if "Mach-O" in output.stdout:
                found.append(path)
    return found


def verify_framework_strings(framework: Path) -> None:
    required = [
        b"NEANTIK_PROFILE_SEED",
        b"NEANTIK_PROFILE_TIMEZONE",
        b"default_public_interface_only",
        b"disable_non_proxied_udp",
        b"DnsOverHttpsUpgrade",
        b"AsyncDns",
        b"WebGPUService",
    ]
    forbidden = [
        b"fingerprint-timezone\0",
        b"fingerprint-locale\0",
        b"fingerprint-platform\0",
        b"apple-device-tuple\0",
    ]
    remaining = set(required)
    found_forbidden: set[bytes] = set()
    tail = b""
    overlap = max(map(len, required + forbidden)) - 1
    with framework.open("rb") as stream:
        while remaining or len(found_forbidden) != len(forbidden):
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            haystack = tail + chunk
            remaining = {item for item in remaining if item not in haystack}
            found_forbidden.update(item for item in forbidden if item in haystack)
            tail = haystack[-overlap:]
    if remaining:
        raise RuntimeCandidateError("runtime is missing required protocol strings")
    if found_forbidden:
        raise RuntimeCandidateError("runtime contains forbidden legacy markers")


def verify(
    app: Path,
    args_gn: Path,
    port_evidence: Path,
    status_path: Path,
) -> dict[str, Any]:
    app = app.resolve()
    if not app.is_absolute() or not app.is_dir() or app.is_symlink():
        raise RuntimeCandidateError("runtime app must be an absolute non-symlink directory")
    status = load_json(status_path.resolve(), "Chromium 153 port status")
    evidence = load_json(port_evidence.resolve(), "Chromium 153 port evidence")
    target = status["targetChromiumVersion"]
    if evidence.get("status") != "candidate-bound" or evidence.get("targetChromiumVersion") != target:
        raise RuntimeCandidateError("port evidence is not bound to the target candidate")

    info = app / "Contents" / "Info.plist"
    executable_name = plist(info, "CFBundleExecutable")
    executable = app / "Contents" / "MacOS" / executable_name
    if plist(info, "CFBundleIdentifier") != "app.neantik.runtime":
        raise RuntimeCandidateError("runtime bundle identifier is not NeAntik")
    if plist(info, "NeAntikRuntimeFlavor") != "fingerprint-chromium":
        raise RuntimeCandidateError("runtime flavor is not fingerprint-chromium")
    actual_version = plist(info, "CFBundleShortVersionString")
    if actual_version != target:
        raise RuntimeCandidateError(f"runtime version mismatch: {actual_version} != {target}")
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeCandidateError("runtime executable is missing or not executable")
    verify_args(args_gn.resolve())

    version_output = run([str(executable), "--version"], "runtime --version")
    if target not in version_output:
        raise RuntimeCandidateError("runtime --version does not contain target version")
    if run(["/usr/bin/lipo", "-archs", str(executable)], "runtime architecture") != "arm64":
        raise RuntimeCandidateError("runtime executable is not arm64-only")

    machos = macho_files(app)
    if not machos:
        raise RuntimeCandidateError("runtime contains no Mach-O files")
    for path in machos:
        if run(["/usr/bin/lipo", "-archs", str(path)], "nested architecture") != "arm64":
            raise RuntimeCandidateError(f"non-arm64 nested code: {path.name}")

    framework_candidates = list((app / "Contents" / "Frameworks").rglob("* Framework"))
    framework = next((path for path in framework_candidates if path.is_file()), None)
    if framework is None:
        raise RuntimeCandidateError("Chromium Framework binary is missing")
    verify_framework_strings(framework)
    signature_details = run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], "read code signature")
    signature_kind = "ad-hoc" if "\nSignature=adhoc\n" in "\n" + signature_details + "\n" else (
        "developer-id" if "\nAuthority=Developer ID Application:" in "\n" + signature_details else "unqualified"
    )
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], "verify code signature")

    executable_sha = sha256_file(executable)
    args_sha = sha256_file(args_gn)
    framework_sha = sha256_file(framework)
    binding = evidence["binaryBinding"]
    if binding["candidateExecutableSHA256"] != executable_sha:
        raise RuntimeCandidateError("port evidence executable hash does not match runtime")
    if binding["argsGNSHA256"] != args_sha:
        raise RuntimeCandidateError("port evidence args.gn hash does not match runtime")

    return {
        "schemaVersion": 1,
        "status": "candidate-runtime-verified",
        "releaseReady": False,
        "targetChromiumVersion": target,
        "architecture": "arm64",
        "gpuMode": "metal",
        "portEvidenceSHA256": sha256_file(port_evidence),
        "buildArgumentsSHA256": args_sha,
        "executable": {"path": f"Contents/MacOS/{executable_name}", "sha256": executable_sha},
        "framework": {"path": str(framework.relative_to(app)), "sha256": framework_sha},
        "machoCount": len(machos),
        "codeSignatureKind": signature_kind,
        "codeSignature": "verified",
        "fingerprintProtocolStrings": "verified",
        "policy": "Local candidate runtime evidence only; signing, notarization, Gatekeeper, publication, and release readiness remain unproven.",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime_app", type=Path)
    parser.add_argument("args_gn", type=Path)
    parser.add_argument("port_evidence", type=Path)
    parser.add_argument("--status", type=Path, default=STATUS_PATH)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args.runtime_app, args.args_gn, args.port_evidence, args.status)
        output = args.output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, delete=False) as temporary:
            json.dump(result, temporary, ensure_ascii=False, indent=2, sort_keys=True)
            temporary.write("\n")
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, output)
    except (OSError, RuntimeCandidateError) as error:
        print(f"Chromium 153 runtime candidate verification failed: {error}", file=sys.stderr)
        return 1
    print(f"PASS: Chromium 153 runtime candidate verified: {output}")
    print(f"Mach-O files: {result['machoCount']} ARM64-only")
    print(f"Signature kind: {result['codeSignatureKind']}")
    print("Release readiness: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
