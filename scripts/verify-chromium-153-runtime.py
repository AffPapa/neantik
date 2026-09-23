#!/usr/bin/env python3
"""Verify one signed ARM64 Chromium 153 runtime and emit bound evidence.

This is the release-time verifier for the explicitly owned macOS packaging
port. It never treats Chromium 152 source evidence as evidence for 153.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


VERSION = "153.0.8010.52"
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must contain an object")
    return value


def run(*command: str) -> str:
    result = subprocess.run(
        list(command), text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, check=False,
    )
    if result.returncode:
        raise ValueError(result.stdout.strip() or "command failed")
    return result.stdout


def plist(path: Path) -> dict[str, object]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a plist dictionary")
    return value


def macho_files(app: Path) -> list[Path]:
    result: list[Path] = []
    for path in app.joinpath("Contents").rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        probe = subprocess.run(
            ["file", "-b", str(path)], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if probe.returncode == 0 and "Mach-O" in probe.stdout:
            result.append(path)
    return result


def verify(args: argparse.Namespace) -> dict[str, object]:
    app = args.app.resolve()
    if not app.is_absolute() or not app.is_dir() or app.is_symlink():
        raise ValueError("runtime app must be an absolute regular directory")
    root = args.project_root.resolve()
    status_path = root / "runtime/chromium-153-port-status.json"
    candidate_path = root / "runtime/chromium-153-port-candidate.json"
    patch_path = root / "runtime/nevision-patches/series.json"
    tuples_path = root / "runtime/apple-device-tuples.json"
    baseline_path = root / "runtime/security-baseline.json"
    for path in (status_path, candidate_path, patch_path, tuples_path, baseline_path):
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing safe provenance file: {path.name}")

    status = load(status_path)
    candidate = load(candidate_path)
    if status.get("targetChromiumVersion") != VERSION:
        raise ValueError("Chromium 153 status targets the wrong version")
    if candidate.get("targetChromiumVersion") != VERSION:
        raise ValueError("Chromium 153 candidate targets the wrong version")
    if candidate.get("sourceEvidenceSHA256") != status["localCandidateEvidence"]["latestCandidateEvidenceSHA256"]:
        raise ValueError("candidate evidence is not the status-bound candidate")
    source_evidence = candidate.get("sourceEvidence")
    if not isinstance(source_evidence, dict) or source_evidence.get("sourceMode") != "owned-macos-packaging-port":
        raise ValueError("candidate does not declare the owned macOS packaging port")

    runtime_info = plist(app / "Contents/Info.plist")
    if runtime_info.get("CFBundleIdentifier") != "app.neantik.runtime":
        raise ValueError("runtime bundle identifier is not app.neantik.runtime")
    if runtime_info.get("CFBundleShortVersionString") != VERSION:
        raise ValueError("runtime Info.plist is not Chromium 153.0.8010.52")
    executable_name = runtime_info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or "/" in executable_name:
        raise ValueError("runtime executable name is invalid")
    executable = app / "Contents/MacOS" / executable_name
    if not executable.is_file() or not executable.stat().st_mode & 0o111:
        raise ValueError("runtime executable is missing or not executable")
    if run("lipo", "-archs", str(executable)).strip() != "arm64":
        raise ValueError("runtime executable is not ARM64-only")
    if f"{VERSION}" not in run(str(executable), "--version"):
        raise ValueError("runtime --version does not report Chromium 153")

    args_text = args.args_gn.read_text(encoding="utf-8")
    if not re.search(r"(?m)^\s*target_cpu\s*=\s*\"arm64\"\s*$", args_text):
        raise ValueError("args.gn does not pin target_cpu=arm64")
    if len(re.findall(r"(?m)^\s*angle_enable_metal\s*=\s*true\s*$", args_text)) != 1:
        raise ValueError("args.gn must enable Metal exactly once")
    if re.search(r"(?m)^\s*angle_enable_metal\s*=\s*false\s*$", args_text):
        raise ValueError("args.gn also disables Metal")

    run("codesign", "--verify", "--deep", "--strict", str(app))
    signature = run("codesign", "-dv", "--verbose=4", str(app))
    if "Authority=Developer ID Application:" not in signature or "Timestamp=" not in signature:
        raise ValueError("runtime is not Developer ID signed with a timestamp")

    binaries = macho_files(app)
    if not binaries:
        raise ValueError("runtime contains no Mach-O code")
    for binary in binaries:
        if run("lipo", "-archs", str(binary)).strip() != "arm64":
            raise ValueError(f"non-ARM64 nested Mach-O: {binary.relative_to(app)}")

    framework = next(app.joinpath("Contents/Frameworks").rglob("* Framework"), None)
    if framework is None or not framework.is_file():
        raise ValueError("Chromium framework binary is missing")
    framework_bytes = framework.read_bytes()
    for marker in (b"NEANTIK_PROFILE_SEED", b"NEANTIK_PROFILE_TIMEZONE", b"default_public_interface_only", b"disable_non_proxied_udp", b"DnsOverHttpsUpgrade", b"AsyncDns", b"WebGPUService"):
        if marker not in framework_bytes:
            raise ValueError(f"runtime is missing required protocol marker: {marker.decode()}")
    for marker in (b"fingerprint-timezone\0", b"fingerprint-locale\0", b"fingerprint-platform\0", b"apple-device-tuple\0"):
        if marker in framework_bytes:
            raise ValueError(f"runtime contains forbidden legacy marker: {marker.decode(errors='replace')}")

    report = {
        "schemaVersion": 3,
        "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "chromiumVersion": VERSION,
        "architecture": "arm64",
        "gpuMode": "metal",
        "sourceLockSHA256": sha256(status_path),
        "candidateLockSHA256": sha256(candidate_path),
        "sourceContractSHA256": sha256(status_path),
        "sourceProvenanceSHA256": sha256(candidate_path),
        "neantikPatchManifestSHA256": sha256(patch_path),
        "appleDeviceTuplesManifestSHA256": sha256(tuples_path),
        "securityBaselineSHA256": sha256(baseline_path),
        "machoCount": len(binaries),
        "executable": {"path": f"Contents/MacOS/{executable_name}", "sha256": sha256(executable)},
        "framework": {"path": framework.relative_to(app).as_posix(), "sha256": sha256(framework)},
        "codeSignature": "verified",
        "codeSignatureKind": "developer-id",
        "fingerprintProtocolStrings": "verified",
        "buildArguments": {"sha256": sha256(args.args_gn)},
    }
    if not all(SHA256.fullmatch(str(value)) for value in (report["sourceLockSHA256"], report["candidateLockSHA256"], report["sourceContractSHA256"], report["sourceProvenanceSHA256"])):
        raise ValueError("runtime report provenance hash is invalid")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--args-gn", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    try:
        report = verify(arguments)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Chromium 153 runtime verification failed: {error}", file=sys.stderr)
        return 65
    print("PASS: signed Chromium 153 runtime verified.")
    print(f"Executable: {report['executable']['sha256']}")
    print(f"Framework:  {report['framework']['sha256']}")
    print(f"Report:     {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
