#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
VERIFIER_PATH = PROJECT_ROOT / "scripts" / "verify-gui-fingerprint-report.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_gui_fingerprint_report_for_candidate_manifest",
    VERIFIER_PATH,
)
assert SPEC and SPEC.loader
GUI_VERIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GUI_VERIFIER
SPEC.loader.exec_module(GUI_VERIFIER)

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RELEASE_CHANNELS = {"public-alpha", "production"}
POST_PREPARATION_MUTABLE_PATHS = {"Contents/CodeResources"}


class CandidateManifestError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_plist(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as file:
            value = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CandidateManifestError(f"Cannot read {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise CandidateManifestError(f"{path.name} must contain a dictionary")
    return value


def regular_bundle_file(app: Path, relative_path: str) -> Path:
    path = app / relative_path
    if not path.is_file() or path.is_symlink():
        raise CandidateManifestError(
            f"Candidate file must be a regular non-symlinked file: {relative_path}"
        )
    try:
        path.resolve().relative_to(app.resolve())
    except (OSError, ValueError) as error:
        raise CandidateManifestError(
            f"Candidate file escapes the app bundle: {relative_path}"
        ) from error
    return path


def hashed_entry(app: Path, relative_path: str) -> dict[str, str]:
    return {
        "bundlePath": relative_path,
        "sha256": sha256_file(regular_bundle_file(app, relative_path)),
    }


def bundle_inventory(app: Path) -> list[dict[str, str | int]]:
    inventory: list[dict[str, str | int]] = [
        {
            "bundlePath": ".",
            "kind": "directory",
            "mode": stat.S_IMODE(app.lstat().st_mode),
        }
    ]
    for root, directory_names, file_names in os.walk(
        app,
        topdown=True,
        followlinks=False,
    ):
        root_path = Path(root)
        for name in sorted(directory_names + file_names):
            path = root_path / name
            relative = path.relative_to(app).as_posix()
            if relative in POST_PREPARATION_MUTABLE_PATHS:
                continue
            status = path.lstat()
            mode = stat.S_IMODE(status.st_mode)
            if path.is_symlink():
                inventory.append(
                    {
                        "bundlePath": relative,
                        "kind": "symlink",
                        "mode": mode,
                        "target": os.readlink(path),
                    }
                )
            elif path.is_file():
                inventory.append(
                    {
                        "bundlePath": relative,
                        "kind": "file",
                        "mode": mode,
                        "size": status.st_size,
                        "sha256": sha256_file(path),
                    }
                )
            elif path.is_dir():
                inventory.append(
                    {
                        "bundlePath": relative,
                        "kind": "directory",
                        "mode": mode,
                    }
                )
            else:
                raise CandidateManifestError(
                    "Candidate contains an unsupported filesystem entry: "
                    + relative
                )
        directory_names[:] = [
            name
            for name in directory_names
            if not (root_path / name).is_symlink()
        ]
    inventory.sort(key=lambda item: str(item["bundlePath"]))
    return inventory


def manifest_payload(
    app: Path,
    *,
    release_channel: str,
    prepared_at: str | None = None,
) -> dict[str, Any]:
    if release_channel not in RELEASE_CHANNELS:
        raise CandidateManifestError(
            "Release channel must be public-alpha or production"
        )
    if not app.is_dir() or app.is_symlink():
        raise CandidateManifestError(
            "Prepared candidate must be a regular app directory"
        )
    info_relative = "Contents/Info.plist"
    info = read_plist(regular_bundle_file(app, info_relative))
    if info.get("CFBundleIdentifier") != "app.neantik.desktop":
        raise CandidateManifestError(
            "Prepared candidate bundle identifier must be app.neantik.desktop"
        )
    executable_name = info.get("CFBundleExecutable")
    if (
        not isinstance(executable_name, str)
        or not executable_name
        or Path(executable_name).name != executable_name
    ):
        raise CandidateManifestError(
            "Prepared candidate has an invalid CFBundleExecutable"
        )
    manager_executable_relative = f"Contents/MacOS/{executable_name}"
    runtime_app = app / "Contents/Resources/NeAntik Browser.app"
    runtime_info = read_plist(
        regular_bundle_file(
            app,
            "Contents/Resources/NeAntik Browser.app/Contents/Info.plist",
        )
    )
    runtime_executable = GUI_VERIFIER._runtime_executable(
        runtime_app,
        runtime_info,
    )
    runtime_framework = GUI_VERIFIER._runtime_framework(runtime_app)
    runtime_executable_relative = runtime_executable.relative_to(app).as_posix()
    runtime_framework_relative = runtime_framework.relative_to(app).as_posix()
    evidence_root = "Contents/Resources/NeAntikRuntimeEvidence"

    return {
        "schemaVersion": 2,
        "kind": "neantik-direct-prepared-candidate",
        "releaseChannel": release_channel,
        "preparedAt": prepared_at
        or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
            "+00:00",
            "Z",
        ),
        "bundle": {
            "name": "NeAntik.app",
            "identifier": "app.neantik.desktop",
            "version": str(info.get("CFBundleShortVersionString", "")),
            "build": str(info.get("CFBundleVersion", "")),
        },
        "criticalFiles": {
            "managerInfoPlist": hashed_entry(app, info_relative),
            "managerExecutable": hashed_entry(app, manager_executable_relative),
            "runtimeInfoPlist": hashed_entry(
                app,
                "Contents/Resources/NeAntik Browser.app/Contents/Info.plist",
            ),
            "runtimeExecutable": hashed_entry(app, runtime_executable_relative),
            "runtimeFramework": hashed_entry(app, runtime_framework_relative),
            "runtimeVerification": hashed_entry(
                app,
                f"{evidence_root}/runtime-verification.json",
            ),
            "runtimeCandidateLock": hashed_entry(
                app,
                f"{evidence_root}/fingerprint-chromium.lock.json",
            ),
            "sourceContract": hashed_entry(
                app,
                f"{evidence_root}/chromium-150-source-contract.json",
            ),
            "sourceProvenance": hashed_entry(
                app,
                f"{evidence_root}/source-provenance.json",
            ),
            "buildArguments": hashed_entry(app, f"{evidence_root}/args.gn"),
        },
        "bundleInventory": bundle_inventory(app),
        "postPreparationMutablePaths": sorted(POST_PREPARATION_MUTABLE_PATHS),
        "boundary": (
            "This manifest binds every regular file, symlink and permission "
            "bit in one prepared Direct candidate except the exact stapler "
            "ticket path listed in postPreparationMutablePaths."
        ),
    }


def encoded_manifest(payload: dict[str, Any]) -> bytes:
    return (
        json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    ).encode("utf-8")


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CandidateManifestError(f"Cannot read candidate manifest: {error}") from error
    if not isinstance(payload, dict):
        raise CandidateManifestError("Candidate manifest must be a JSON object")
    expected_keys = {
        "boundary",
        "bundle",
        "bundleInventory",
        "criticalFiles",
        "kind",
        "preparedAt",
        "postPreparationMutablePaths",
        "releaseChannel",
        "schemaVersion",
    }
    if set(payload) != expected_keys:
        raise CandidateManifestError(
            "Candidate manifest has an invalid exact key set"
        )
    if payload.get("schemaVersion") != 2:
        raise CandidateManifestError("Candidate manifest schemaVersion must be 2")
    if payload.get("postPreparationMutablePaths") != sorted(
        POST_PREPARATION_MUTABLE_PATHS
    ):
        raise CandidateManifestError(
            "Candidate manifest mutable-path boundary is invalid"
        )
    if payload.get("kind") != "neantik-direct-prepared-candidate":
        raise CandidateManifestError("Candidate manifest kind is invalid")
    GUI_VERIFIER.parse_iso8601(payload.get("preparedAt"), "preparedAt")
    return payload


def verify_manifest(
    app: Path,
    manifest: Path,
    *,
    release_channel: str,
) -> str:
    payload = load_manifest(manifest)
    if payload.get("releaseChannel") != release_channel:
        raise CandidateManifestError(
            "Candidate manifest release channel does not match the requested channel"
        )
    expected = manifest_payload(
        app,
        release_channel=release_channel,
        prepared_at=str(payload["preparedAt"]),
    )
    if payload != expected:
        raise CandidateManifestError(
            "Prepared candidate changed after its manifest was created"
        )
    return hashlib.sha256(encoded_manifest(payload)).hexdigest()


def verify_evidence_follows_manifest(manifest: Path, evidence: Path) -> None:
    payload = load_manifest(manifest)
    report = GUI_VERIFIER.load_report(evidence)
    prepared_at = GUI_VERIFIER.parse_iso8601(payload.get("preparedAt"), "preparedAt")
    report_created_at = GUI_VERIFIER.parse_iso8601(
        report.get("createdAt"),
        "createdAt",
    )
    if report_created_at < prepared_at:
        raise CandidateManifestError(
            "GUI evidence predates the prepared immutable candidate"
        )


def write_manifest(path: Path, payload: dict[str, Any]) -> str:
    if path.exists() or path.is_symlink():
        raise CandidateManifestError(
            "Candidate manifest already exists; refusing overwrite"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    data = encoded_manifest(payload)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Create or verify the immutable code-critical manifest for one "
            "prepared NeAntik Direct candidate."
        )
    )
    parser.add_argument("mode", choices=("create", "verify"))
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--release-channel",
        choices=("public-alpha", "production"),
        required=True,
    )
    parser.add_argument(
        "--fingerprint-evidence",
        type=Path,
        help=(
            "With verify, require GUI evidence created after this candidate "
            "manifest."
        ),
    )
    args = parser.parse_args()
    try:
        if args.mode == "create":
            digest = write_manifest(
                args.manifest,
                manifest_payload(args.app, release_channel=args.release_channel),
            )
        else:
            digest = verify_manifest(
                args.app,
                args.manifest,
                release_channel=args.release_channel,
            )
            if args.fingerprint_evidence is not None:
                verify_evidence_follows_manifest(
                    args.manifest,
                    args.fingerprint_evidence,
                )
    except (
        CandidateManifestError,
        GUI_VERIFIER.FingerprintReportError,
        OSError,
    ) as error:
        print(f"Candidate manifest verification failed: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: prepared Direct candidate manifest is exact; "
        f"SHA-256 {digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
