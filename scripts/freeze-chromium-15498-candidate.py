#!/usr/bin/env python3
"""Freeze the exact M154.98 source and unsigned binary for Direct qualification.

This creates source-only evidence. It does not approve signing or publication.
The output set is created once; changing any input requires a fresh candidate.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import plistlib
import sys
from pathlib import Path

from chromium_15498_release_evidence import (
    COMMIT,
    EVIDENCE_NAMES,
    TREE,
    VERSION,
    verify_candidate_document,
    verify_candidate_lock,
    verify_contract,
    verify_unsigned_binary_binding,
)
from chromium_15498_source_snapshot import build_snapshot, compact_snapshot


PROJECT = Path(__file__).resolve().parents[1]
RUNTIME = PROJECT / "runtime"
PREFIX = "chromium-15498"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_new(path: Path, document: dict, created: list[Path]) -> None:
    if path.exists() or path.is_symlink():
        raise ValueError(f"refusing to replace frozen evidence: {path.name}")
    temporary = path.with_name(path.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError(f"temporary evidence path is occupied: {temporary.name}")
    try:
        temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(path)
    except OSError:
        temporary.unlink(missing_ok=True)
        raise
    created.append(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("args_gn", type=Path)
    parser.add_argument("unsigned_app", type=Path)
    args = parser.parse_args()
    created: list[Path] = []
    try:
        source = args.source_root
        app = args.unsigned_app
        args_gn = args.args_gn
        if any(not path.is_absolute() or path.is_symlink() for path in (source, app, args_gn)):
            raise ValueError("all inputs must be absolute, non-symlink paths")
        if not app.is_dir() or not source.is_dir() or not args_gn.is_file():
            raise ValueError("source, args.gn, or unsigned app is missing")
        names = (
            f"{PREFIX}-source-snapshot.json",
            f"{PREFIX}-source-input-manifest.json",
            f"{PREFIX}-source-contract.json",
            f"{PREFIX}-port-candidate.json",
            f"fingerprint-{PREFIX}.lock.json",
        )
        for name in names:
            if (RUNTIME / name).exists() or (RUNTIME / name).is_symlink():
                raise ValueError(f"candidate evidence already exists: {name}")

        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        executable_name = info.get("CFBundleExecutable")
        if info.get("CFBundleShortVersionString") != VERSION or not isinstance(executable_name, str) or "/" in executable_name:
            raise ValueError("unsigned app is not the exact M154.98 build")
        executable = app / "Contents/MacOS" / executable_name
        framework = app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / VERSION / "NeAntik Browser Framework"
        if any(path.is_symlink() or not path.is_file() for path in (executable, framework)):
            raise ValueError("unsigned executable or versioned framework is missing")

        snapshot = compact_snapshot(build_snapshot(source, args_gn))
        write_new(RUNTIME / names[0], snapshot, created)
        args_hash = digest(args_gn)
        evidence_dir = RUNTIME / f"{PREFIX}-source-evidence"
        manifest = {
            "schemaVersion": 1,
            "chromiumVersion": VERSION,
            "status": "source-reconstructed",
            "sourceInputsReady": True,
            "releaseReady": False,
            "sourceSnapshotSHA256": digest(RUNTIME / names[0]),
            "buildArgsSHA256": args_hash,
            "evidence": [
                {"path": name, "sha256": digest(evidence_dir / name)}
                for name in EVIDENCE_NAMES
            ],
        }
        write_new(RUNTIME / names[1], manifest, created)
        contract = {
            "schemaVersion": 2,
            "status": "source-qualified",
            "releaseReady": False,
            "targetChromiumVersion": VERSION,
            "targetArchitecture": "arm64",
            "sourceMode": "official-chromium-owned-macos-port",
            "safeBrowsingMode": 0,
            "enterpriseCloudContentAnalysis": True,
            "officialChromiumBase": {"commit": COMMIT, "tree": TREE},
            "buildArgsSHA256": args_hash,
            "sourceSnapshotSHA256": digest(RUNTIME / names[0]),
            "sourceInputManifestSHA256": digest(RUNTIME / names[1]),
            "toolchainLockSHA256": digest(RUNTIME / f"{PREFIX}-toolchain-lock.json"),
            "securityBaselineSHA256": digest(RUNTIME / "security-baseline.json"),
            "appleDeviceTuplesSHA256": digest(RUNTIME / "apple-device-tuples.json"),
            "rebasePlanSHA256": digest(RUNTIME / f"{PREFIX}-rebase-plan.json"),
            "ownedPatchGroupCount": 73,
        }
        write_new(RUNTIME / names[2], contract, created)
        verify_contract(PROJECT)
        candidate = {
            "schemaVersion": 1,
            "status": "candidate-bound",
            "releaseReady": False,
            "targetChromiumVersion": VERSION,
            "targetArchitecture": "arm64",
            "sourceContractSHA256": digest(RUNTIME / names[2]),
            "sourceInputManifestSHA256": digest(RUNTIME / names[1]),
            "sourceSnapshotSHA256": digest(RUNTIME / names[0]),
            "binaryBinding": {
                "status": "bound-to-built-candidate",
                "sourceVersion": VERSION,
                "architecture": "arm64",
                "argsGNSHA256": args_hash,
                "candidateExecutableSHA256": digest(executable),
                "candidateFrameworkSHA256": digest(framework),
            },
            "policy": "Source and unsigned build only; signed runtime and release gates remain required.",
        }
        write_new(RUNTIME / names[3], candidate, created)
        verify_candidate_document(candidate, project_root=PROJECT)
        verify_unsigned_binary_binding(app, args_gn, candidate)

        previous = json.loads((RUNTIME / "fingerprint-chromium-154.lock.json").read_text(encoding="utf-8"))
        lock = copy.deepcopy(previous)
        lock["fingerprintChromium"].update({
            "chromiumVersion": VERSION,
            "commit": COMMIT,
            "tree": TREE,
            "tag": VERSION,
            "licenseSHA256": digest(source / "LICENSE"),
        })
        lock["macPackaging"]["packagedChromiumVersion"] = VERSION
        lock["ownedManifests"]["securityBaselineSHA256"] = digest(RUNTIME / "security-baseline.json")
        lock["sourceContract"] = f"runtime/{names[2]}"
        lock["sourceContractSHA256"] = digest(RUNTIME / names[2])
        lock["sourceProvenance"] = f"runtime/{names[3]}"
        lock["sourceProvenanceSHA256"] = digest(RUNTIME / names[3])
        lock["verification"] = {
            "coherentAppleDeviceTuples": "pending-runtime-evidence",
            "scope": "Exact signed runtime GUI and same-origin JS/HTTP Device Memory evidence pending.",
        }
        write_new(RUNTIME / names[4], lock, created)
        verify_candidate_lock(lock, provenance=candidate, project_root=PROJECT)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        for path in reversed(created):
            path.unlink(missing_ok=True)
        print(f"M154.98 candidate freeze failed: {error}", file=sys.stderr)
        return 1
    print("PASS: exact M154.98 source snapshot and unsigned binary are frozen; runtime qualification remains pending")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
