#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


class PackagedRuntimeReportError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise PackagedRuntimeReportError(f"Missing regular JSON file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PackagedRuntimeReportError(
            f"Cannot read JSON file {path}: {error}"
        ) from error
    if not isinstance(value, dict):
        raise PackagedRuntimeReportError(f"JSON root must be an object: {path}")
    return value


def field(value: dict[str, Any], dotted: str) -> Any:
    current: Any = value
    for component in dotted.split("."):
        if not isinstance(current, dict) or component not in current:
            raise PackagedRuntimeReportError(
                f"Runtime report is missing immutable field {dotted}"
            )
        current = current[component]
    return current


def canonical_bundle_file(
    runtime_app: Path,
    recorded: Any,
    prefix: str,
) -> Path:
    if not isinstance(recorded, str):
        raise PackagedRuntimeReportError("Runtime bundle path must be a string")
    relative = Path(recorded)
    if (
        relative.is_absolute()
        or not recorded.startswith(prefix)
        or ".." in relative.parts
        or "." in relative.parts
    ):
        raise PackagedRuntimeReportError(
            f"Runtime bundle path is not canonical: {recorded}"
        )
    path = runtime_app / relative
    if not path.is_file() or path.is_symlink():
        raise PackagedRuntimeReportError(
            f"Recorded runtime file is missing or unsafe: {recorded}"
        )
    return path


def command_output(arguments: list[str]) -> str:
    completed = subprocess.run(
        arguments,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout + completed.stderr


def signature_kind(runtime_app: Path) -> str:
    details = command_output(
        ["codesign", "-dv", "--verbose=4", str(runtime_app)]
    )
    if re.search(r"^Signature=adhoc$", details, re.MULTILINE):
        return "ad-hoc"
    if re.search(
        r"^Authority=Developer ID Application:",
        details,
        re.MULTILINE,
    ):
        return "developer-id"
    if re.search(r"^Authority=", details, re.MULTILINE):
        return "identity"
    return "unclassified"


def macho_count(runtime_app: Path) -> int:
    count = 0
    for path in runtime_app.joinpath("Contents").rglob("*"):
        if (
            path.is_file()
            and not path.is_symlink()
            and (os.access(path, os.X_OK) or path.suffix == ".dylib")
            and "Mach-O" in command_output(["file", "-b", str(path)])
        ):
            architectures = command_output(["lipo", "-archs", str(path)]).strip()
            if architectures != "arm64":
                raise PackagedRuntimeReportError(
                    f"Packaged runtime contains non-ARM64 code: {path}"
                )
            count += 1
    if count == 0:
        raise PackagedRuntimeReportError(
            "Packaged runtime contains no Mach-O code"
        )
    return count


def gpu_mode(args_path: Path) -> str:
    text = args_path.read_text(encoding="utf-8")
    metal_true = len(
        re.findall(r"(?m)^\s*angle_enable_metal\s*=\s*true\s*$", text)
    )
    metal_false = len(
        re.findall(r"(?m)^\s*angle_enable_metal\s*=\s*false\s*$", text)
    )
    if metal_true == 1 and metal_false == 0:
        return "metal"
    if metal_false == 1 and metal_true == 0:
        return "no-metal"
    raise PackagedRuntimeReportError(
        "Packaged args.gn must declare exactly one Metal mode"
    )


def verify(
    report_path: Path,
    runtime_app: Path,
    evidence: Path,
    project_root: Path,
) -> None:
    if (
        not runtime_app.is_absolute()
        or not runtime_app.is_dir()
        or runtime_app.is_symlink()
    ):
        raise PackagedRuntimeReportError(
            "Runtime app must be an absolute regular directory"
        )
    if not evidence.is_dir() or evidence.is_symlink():
        raise PackagedRuntimeReportError(
            "Runtime evidence must be a regular directory"
        )

    report = load_json(report_path)
    if field(report, "schemaVersion") != 3:
        raise PackagedRuntimeReportError(
            "Packaged runtime report must use schema 3"
        )

    with (runtime_app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    executable = canonical_bundle_file(
        runtime_app,
        field(report, "executable.path"),
        "Contents/MacOS/",
    )
    framework = canonical_bundle_file(
        runtime_app,
        field(report, "framework.path"),
        "Contents/Frameworks/",
    )

    evidence_files = {
        "sourceLockSHA256": project_root
        / "runtime/fingerprint-chromium.lock.json",
        "candidateLockSHA256": evidence / "fingerprint-chromium.lock.json",
        "sourceContractSHA256": evidence / "chromium-151-source-contract.json",
        "sourceProvenanceSHA256": evidence / "source-provenance.json",
        "neantikPatchManifestSHA256": evidence / "neantik-patch-series.json",
        "appleDeviceTuplesManifestSHA256": evidence / "apple-device-tuples.json",
        "securityBaselineSHA256": evidence / "security-baseline.json",
        "buildArguments.sha256": evidence / "args.gn",
    }
    for path in evidence_files.values():
        if not path.is_file() or path.is_symlink():
            raise PackagedRuntimeReportError(
                f"Packaged runtime evidence is missing or unsafe: {path}"
            )

    command_output(
        ["codesign", "--verify", "--deep", "--strict", str(runtime_app)]
    )
    actual = {
        "chromiumVersion": info.get("CFBundleShortVersionString"),
        "architecture": command_output(
            ["lipo", "-archs", str(executable)]
        ).strip(),
        "gpuMode": gpu_mode(evidence / "args.gn"),
        "machoCount": macho_count(runtime_app),
        "codeSignature": "verified",
        "codeSignatureKind": signature_kind(runtime_app),
        "fingerprintProtocolStrings": "verified",
        "executable.path": field(report, "executable.path"),
        "executable.sha256": sha256(executable),
        "framework.path": field(report, "framework.path"),
        "framework.sha256": sha256(framework),
    }
    actual.update(
        {name: sha256(path) for name, path in evidence_files.items()}
    )

    mismatches = [
        name for name, value in actual.items() if field(report, name) != value
    ]
    if mismatches:
        raise PackagedRuntimeReportError(
            "Packaged runtime report does not match the distributed bundle: "
            + ", ".join(mismatches)
        )

    build_arguments = field(report, "buildArguments")
    if (
        not isinstance(build_arguments, dict)
        or set(build_arguments) != {"sha256"}
    ):
        raise PackagedRuntimeReportError(
            "Runtime report buildArguments must contain only sha256"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--runtime-app", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--project-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(
            args.report,
            args.runtime_app,
            args.evidence,
            args.project_root,
        )
    except (
        OSError,
        PackagedRuntimeReportError,
        plistlib.InvalidFileException,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Packaged runtime report verification failed: {error}", file=sys.stderr)
        return 65
    print("Packaged runtime report matches the distributed runtime.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
