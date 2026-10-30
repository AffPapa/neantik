#!/usr/bin/env python3
"""Freeze the exact M155.40 source and unsigned binary for Direct qualification.

This creates source-only evidence. It does not approve signing or publication.
The output set is created once; changing any input requires a fresh candidate.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import plistlib
import sys
from pathlib import Path

from chromium_15540_release_evidence import (
    COMMIT,
    EVIDENCE_NAMES,
    TREE,
    VERSION,
    verify_candidate_document,
    verify_candidate_lock,
    verify_contract,
    verify_unsigned_binary_binding,
    final_overlay_postimages,
    safe_relative_regular,
)
from chromium_15540_source_snapshot import build_snapshot, compact_snapshot


PROJECT = Path(__file__).resolve().parents[1]
RUNTIME = PROJECT / "runtime"
PREFIX = "chromium-15540"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def remove_owned(record: tuple[Path, int, int, str]) -> None:
    """Roll back only bytes and inode created by this freeze attempt."""
    path, device, inode, expected_hash = record
    try:
        stat = path.lstat()
        if not path.is_symlink() and (stat.st_dev, stat.st_ino) == (device, inode) and digest(path) == expected_hash:
            path.unlink()
    except OSError:
        pass


def write_new(path: Path, document: dict, created: list[tuple[Path, int, int, str]]) -> None:
    if path.exists() or path.is_symlink():
        raise ValueError(f"refusing to replace frozen evidence: {path.name}")
    temporary = path.with_name(path.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError(f"temporary evidence path is occupied: {temporary.name}")
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    expected_hash = hashlib.sha256(payload).hexdigest()
    temporary_record = None
    try:
        with temporary.open("xb") as stream:
            stat = os.fstat(stream.fileno())
            temporary_record = (temporary, stat.st_dev, stat.st_ino, expected_hash)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        # link is exclusive: a competing destination is never replaced.
        os.link(temporary, path, follow_symlinks=False)
        created.append((path, stat.st_dev, stat.st_ino, expected_hash))
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if temporary_record is not None:
            # A partial write is still ours, but a replacement inode is not.
            try:
                stat = temporary.lstat()
                if (stat.st_dev, stat.st_ino) == temporary_record[1:3] and not temporary.is_symlink():
                    temporary.unlink()
            except OSError:
                pass


def verify_prebuild_snapshot(path: Path, snapshot: dict, plan: dict) -> str:
    """Require the reviewed pre-build inventory, never rebaseline after a build."""
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError("an absolute regular pre-build snapshot is required")
    expected_hash = plan.get("buildPolicy", {}).get("sourceInputSnapshotSHA256")
    observed_hash = digest(path)
    if observed_hash != expected_hash:
        raise ValueError("pre-build snapshot differs from reviewed build input")
    if json.loads(path.read_text(encoding="utf-8")) != snapshot:
        raise ValueError("source or build arguments changed after the pre-build snapshot")
    return observed_hash


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("args_gn", type=Path)
    parser.add_argument("unsigned_app", type=Path)
    parser.add_argument("--prebuild-snapshot", type=Path, required=True)
    args = parser.parse_args()
    created: list[tuple[Path, int, int, str]] = []
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
            raise ValueError("unsigned app is not the exact M155.40 build")
        executable = app / "Contents/MacOS" / executable_name
        framework = app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / VERSION / "NeAntik Browser Framework"
        if any(path.is_symlink() or not path.is_file() for path in (executable, framework)):
            raise ValueError("unsigned executable or versioned framework is missing")

        for name, expected in final_overlay_postimages(RUNTIME).items():
            if digest(safe_relative_regular(source, name)) != expected:
                raise ValueError("M155.40 final source postimage mismatch before freeze")
        snapshot = compact_snapshot(build_snapshot(source, args_gn))
        plan = json.loads((RUNTIME / f"{PREFIX}-rebase-plan.json").read_text())
        prebuild_hash = verify_prebuild_snapshot(args.prebuild_snapshot, snapshot, plan)
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
            "sourceInputSnapshotSHA256": prebuild_hash,
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
        for lock_key, plan_key in (("commonChromium", "upstreamCommonOverlay"), ("macPackaging", "upstreamMacPackaging")):
            for key in ("repository", "commit", "tree"):
                lock[lock_key][key] = plan[plan_key][key]
        lock["binaryBinding"] = {"requiredEvidence": f"runtime/{PREFIX}-port-candidate.json",
                                 "status": "bound-by-source-candidate-and-runtime-report"}
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
        for record in reversed(created):
            remove_owned(record)
        print(f"M155.40 candidate freeze failed: {error}", file=sys.stderr)
        return 1
    print("PASS: exact M155.40 source snapshot and unsigned binary are frozen; runtime qualification remains pending")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
