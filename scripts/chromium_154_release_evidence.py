#!/usr/bin/env python3
"""Fail-closed evidence checks for the Chromium 154 owned source port.

The existing Chromium 152 provenance model assumes a lite source archive and
two Git repositories. M154 is an official Chromium Git checkout with pinned
upstream packaging/common overlays and an ordered NeAntik patch port. Keep this
route explicit so M154 cannot fall through to M152 evidence.
"""

from __future__ import annotations

import hashlib
import json
import plistlib
import re
from pathlib import Path
from typing import Any


VERSION = "154.0.8037.93"
COMMIT = "f89f3a4363808e117c592adedcf9947882ac3b79"
TREE = "658e81c77627fcf91e6784bd353e0d31a4ca70b5"
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class M154EvidenceError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise M154EvidenceError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise M154EvidenceError(f"{label} must be a JSON object")
    return value


def reject_local_paths(value: Any, label: str = "M154 evidence") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            reject_local_paths(child, f"{label}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_local_paths(child, f"{label}[{index}]")
    elif isinstance(value, str) and (
        value.startswith("/")
        or value.startswith("file:")
        or "/Users/" in value
        or "/private/tmp/" in value
        or "/var/folders/" in value
    ):
        raise M154EvidenceError(f"{label} contains a local absolute path")


def verify_snapshot_binding(
    snapshot: dict[str, Any], contract: dict[str, Any], snapshot_path: Path
) -> None:
    # Legacy schema 1 used the input-manifest field for the snapshot itself.
    # An explicit snapshot field takes precedence, including invalid values:
    # never fall back from malformed new evidence to a legacy digest.
    expected = (
        contract["sourceSnapshotSHA256"]
        if "sourceSnapshotSHA256" in contract
        else contract.get("sourceInputManifestSHA256")
    )
    if not isinstance(expected, str) or not HEX64.fullmatch(expected):
        raise M154EvidenceError("M154 source snapshot binding is invalid")
    if snapshot_path.is_symlink() or not snapshot_path.is_file():
        raise M154EvidenceError("M154 source snapshot file is missing or unsafe")
    if snapshot.get("sha256") != expected or sha256_file(snapshot_path) != expected:
        raise M154EvidenceError("M154 source snapshot digest differs from the candidate contract")


def verify_input_manifest_binding(
    contract: dict[str, Any], manifest_path: Path
) -> dict[str, Any]:
    """Bind the separate manifest bytes; qualification is checked by its route."""
    expected = contract.get("sourceInputManifestSHA256")
    if not isinstance(expected, str) or not HEX64.fullmatch(expected):
        raise M154EvidenceError("M154 input manifest binding is invalid")
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise M154EvidenceError("M154 input manifest file is missing or unsafe")
    if sha256_file(manifest_path) != expected:
        raise M154EvidenceError("M154 input manifest digest differs from the source contract")
    manifest = read_object(manifest_path, "M154 input manifest")
    reject_local_paths(manifest, "M154 input manifest")
    for key in ("sourceSnapshotSHA256", "buildArgsSHA256"):
        if manifest.get(key) != contract.get(key) or not isinstance(manifest.get(key), str) or not HEX64.fullmatch(manifest[key]):
            raise M154EvidenceError(f"M154 input manifest {key} differs from the source contract")
    if manifest.get("chromiumVersion") != VERSION:
        raise M154EvidenceError("M154 input manifest targets the wrong Chromium version")
    return manifest


def verify_contract(
    contract: dict[str, Any],
    *,
    contract_path: Path,
    project_root: Path,
) -> None:
    reject_local_paths(contract, "M154 source contract")
    if contract.get("schemaVersion") not in (1, 2) or contract.get("status") != "source-qualified":
        raise M154EvidenceError("M154 source contract is not source-qualified")
    if contract.get("targetChromiumVersion") != VERSION or contract.get("targetArchitecture") != "arm64":
        raise M154EvidenceError("M154 source contract targets the wrong runtime")
    if contract.get("sourceMode") != "official-chromium-owned-macos-port":
        raise M154EvidenceError("M154 source contract has an unexpected source mode")
    if contract.get("safeBrowsingMode") != 0 or contract.get("enterpriseCloudContentAnalysis") is not True:
        raise M154EvidenceError("M154 security build flags do not match the locked policy")
    official = contract.get("officialChromiumBase")
    if not isinstance(official, dict) or (official.get("commit"), official.get("tree")) != (COMMIT, TREE):
        raise M154EvidenceError("M154 official Chromium commit/tree do not match the lock")
    for key in ("sourceInputManifestSHA256", "buildArgsSHA256", "portExperimentSHA256"):
        if not isinstance(contract.get(key), str) or not HEX64.fullmatch(contract[key]):
            raise M154EvidenceError(f"M154 source contract {key} is not a SHA-256")
    runtime = project_root / "runtime"
    if contract["schemaVersion"] == 2:
        manifest = verify_input_manifest_binding(
            contract, runtime / "chromium-154-source-input-manifest.json"
        )
        if (manifest.get("status") != "source-reconstructed"
                or manifest.get("sourceInputsReady") is not True):
            raise M154EvidenceError("M154 reconstructed source inputs are not qualified")
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "chromium_154_reconstruction", Path(__file__).with_name("chromium_154_reconstruction.py")
        )
        if spec is None or spec.loader is None:
            raise M154EvidenceError("M154 reconstruction verifier is unavailable")
        reconstruction = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reconstruction)
        experiment_for_reconstruction = read_object(
            runtime / "nevision-patches/ports/chromium-154.0.8037.93/port-experiment.json",
            "M154 port experiment",
        )
        try:
            reconstruction.verify_reconstruction(
                runtime / "chromium-154-source-evidence", manifest, experiment_for_reconstruction
            )
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise M154EvidenceError(f"M154 source reconstruction failed: {error}") from error
    elif "sourceSnapshotSHA256" in contract:
        raise M154EvidenceError("Separate M154 source manifests require contract schema 2")
    experiment_path = runtime / "nevision-patches/ports/chromium-154.0.8037.93/port-experiment.json"
    tuples_path = runtime / "apple-device-tuples.json"
    security_path = runtime / "security-baseline.json"
    toolchain_path = runtime / "chromium-154-toolchain-lock.json"
    for path, expected, label in (
        (experiment_path, contract["portExperimentSHA256"], "port experiment"),
        (tuples_path, contract.get("appleDeviceTuplesSHA256"), "Apple tuple catalog"),
        (security_path, contract.get("securityBaselineSHA256"), "security baseline"),
        (toolchain_path, contract.get("toolchainLockSHA256"), "toolchain lock"),
    ):
        if not path.is_file() or path.is_symlink() or sha256_file(path) != expected:
            raise M154EvidenceError(f"M154 {label} digest mismatch")
    experiment = read_object(experiment_path, "M154 port experiment")
    groups = experiment.get("ownedPatchApplyCheck", {}).get("groups", [])
    if len(groups) != contract.get("ownedPatchGroupCount") or contract.get("ownedPatchGroupCount") != 73:
        raise M154EvidenceError("M154 owned patch group count is not the reviewed 73")
    if any(group.get("sequentialApplyCheck") not in {"passed", "already-satisfied-by-common-overlay"} for group in groups):
        raise M154EvidenceError("M154 owned patch replay has an unverified group")
    if contract_path.is_symlink() or not contract_path.is_file():
        raise M154EvidenceError("M154 source contract is missing or symlinked")


def verify_candidate_document(
    document: dict[str, Any],
    *,
    project_root: Path,
    source_root: Path | None = None,
) -> None:
    runtime = project_root.resolve() / "runtime"
    candidate_path = runtime / "chromium-154-port-candidate.json"
    contract_path = runtime / "chromium-154-source-contract.json"
    if not candidate_path.is_file() or candidate_path.is_symlink():
        raise M154EvidenceError("M154 built candidate evidence is missing")
    canonical = read_object(candidate_path, "M154 built candidate")
    if document != canonical:
        raise M154EvidenceError("M154 source provenance differs from the checked candidate")
    if document.get("schemaVersion") != 1 or document.get("status") != "candidate-bound":
        raise M154EvidenceError("M154 candidate is not bound")
    if document.get("releaseReady") is not False:
        raise M154EvidenceError("M154 candidate must not claim release readiness")
    if document.get("targetChromiumVersion") != VERSION or document.get("targetArchitecture") != "arm64":
        raise M154EvidenceError("M154 candidate targets the wrong runtime")
    contract = read_object(contract_path, "M154 source contract")
    verify_contract(contract, contract_path=contract_path, project_root=project_root)
    if document.get("sourceContractSHA256") != sha256_file(contract_path):
        raise M154EvidenceError("M154 candidate is not bound to its source contract")
    if document.get("sourceInputManifestSHA256") != contract.get("sourceInputManifestSHA256"):
        raise M154EvidenceError("M154 candidate source-input manifest is stale")
    snapshot = document.get("sourceSnapshot")
    if not isinstance(snapshot, dict):
        raise M154EvidenceError("M154 candidate has no exact source snapshot binding")
    snapshot_path = runtime / "chromium-154-source-snapshot.json"
    verify_snapshot_binding(snapshot, contract, snapshot_path)
    if source_root is not None:
        snapshot_script = Path(__file__).resolve().with_name(
            "chromium_154_source_snapshot.py"
        )
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "chromium_154_source_snapshot", snapshot_script
        )
        if spec is None or spec.loader is None:
            raise M154EvidenceError("M154 live source snapshot verifier is unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        stored_snapshot = read_object(snapshot_path, "M154 source snapshot")
        args_relative = stored_snapshot.get("argsGN", {}).get("relativePath")
        if not isinstance(args_relative, str):
            raise M154EvidenceError("M154 source snapshot has no args.gn path")
        try:
            current_snapshot = module.build_snapshot(
                source_root,
                source_root / args_relative,
            )
            if stored_snapshot.get("schemaVersion") == 2:
                current_snapshot = module.compact_snapshot(current_snapshot)
        except (OSError, ValueError) as error:
            raise M154EvidenceError(f"M154 live source snapshot failed: {error}") from error
        if current_snapshot != stored_snapshot:
            raise M154EvidenceError("M154 live source differs from its frozen snapshot")
        if contract.get("schemaVersion") == 2:
            reconstruction_spec = importlib.util.spec_from_file_location(
                "chromium_154_reconstruction", Path(__file__).with_name("chromium_154_reconstruction.py")
            )
            if reconstruction_spec is None or reconstruction_spec.loader is None:
                raise M154EvidenceError("M154 live external input verifier is unavailable")
            reconstruction = importlib.util.module_from_spec(reconstruction_spec)
            reconstruction_spec.loader.exec_module(reconstruction)
            manifest = read_object(runtime / "chromium-154-source-input-manifest.json", "M154 input manifest")
            try:
                evidence_paths = reconstruction.bound_evidence(runtime / "chromium-154-source-evidence", manifest)
                reconstruction.verify_live_external_inputs(source_root, evidence_paths)
            except (OSError, ValueError, KeyError, TypeError) as error:
                raise M154EvidenceError(f"M154 live external input verification failed: {error}") from error
    binary = document.get("binaryBinding")
    if not isinstance(binary, dict) or binary.get("status") != "bound-to-built-candidate":
        raise M154EvidenceError("M154 candidate has no built-binary binding")
    if binary.get("sourceVersion") != VERSION or binary.get("architecture") != "arm64":
        raise M154EvidenceError("M154 binary binding does not match the locked runtime")
    for key in ("argsGNSHA256", "candidateExecutableSHA256", "candidateFrameworkSHA256"):
        if not isinstance(binary.get(key), str) or not HEX64.fullmatch(binary[key]):
            raise M154EvidenceError(f"M154 binary binding {key} is invalid")
    if binary.get("argsGNSHA256") != contract.get("buildArgsSHA256"):
        raise M154EvidenceError("M154 candidate build args do not match the source contract")
    reject_local_paths(document)


def verify_unsigned_binary_binding(app: Path, args_gn: Path, document: dict[str, Any]) -> None:
    """Bind build output before codesign changes executable bytes."""
    if app.is_symlink() or not app.is_dir():
        raise M154EvidenceError("M154 candidate app is missing or symlinked")
    app = app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name or "/" in name or name in {".", ".."}:
        raise M154EvidenceError("M154 candidate executable name is invalid")
    if info.get("CFBundleShortVersionString") != VERSION:
        raise M154EvidenceError("M154 candidate bundle version mismatch")
    binding = document.get("binaryBinding", {})
    paths = (
        (app / "Contents/MacOS" / name, "candidateExecutableSHA256"),
        (app / "Contents/Frameworks/NeAntik Browser Framework.framework/Versions" / VERSION
         / "NeAntik Browser Framework", "candidateFrameworkSHA256"),
        (args_gn, "argsGNSHA256"),
    )
    for path, key in paths:
        expected = binding.get(key)
        if not isinstance(expected, str) or not HEX64.fullmatch(expected):
            raise M154EvidenceError(f"M154 unsigned binding {key} is invalid")
        if path.is_symlink() or not path.is_file():
            raise M154EvidenceError(f"M154 unsigned input {key} is missing or symlinked")
        if key != "argsGNSHA256" and not path.resolve().is_relative_to(app):
            raise M154EvidenceError("M154 candidate binary escapes its bundle")
        if sha256_file(path) != expected:
            raise M154EvidenceError(f"M154 unsigned input {key} digest mismatch")


def verify_candidate_lock(
    lock: dict[str, Any],
    *,
    provenance: dict[str, Any],
    project_root: Path,
) -> None:
    runtime = project_root.resolve() / "runtime"
    lock_path = runtime / "fingerprint-chromium-154.lock.json"
    if not lock_path.is_file() or lock_path.is_symlink():
        raise M154EvidenceError("M154 candidate runtime lock is missing")
    canonical = read_object(lock_path, "M154 candidate runtime lock")
    if lock != canonical:
        raise M154EvidenceError("M154 runtime lock differs from the checked candidate lock")
    verify_candidate_document(provenance, project_root=project_root)
    contract_path = runtime / "chromium-154-source-contract.json"
    if lock.get("schemaVersion") != 4 or lock.get("status") != "source-qualified":
        raise M154EvidenceError("M154 runtime lock must use source-qualified schema 4")
    fingerprint = lock.get("fingerprintChromium")
    if not isinstance(fingerprint, dict) or fingerprint.get("chromiumVersion") != VERSION:
        raise M154EvidenceError("M154 runtime lock targets the wrong Chromium version")
    if lock.get("sourceContractSHA256") != sha256_file(contract_path):
        raise M154EvidenceError("M154 runtime lock is not bound to its source contract")
    if lock.get("sourceProvenanceSHA256") != sha256_file(runtime / "chromium-154-port-candidate.json"):
        raise M154EvidenceError("M154 runtime lock is not bound to its candidate evidence")
    reject_local_paths(lock)
