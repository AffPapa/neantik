#!/usr/bin/env python3
"""Closed source/candidate evidence for the Chromium 156.0.8078.48 port."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
from typing import Any

VERSION = "156.0.8078.48"
PREFIX = "chromium-15648"
CONTRACT = PREFIX + "-source-contract.json"
PLAN = PREFIX + "-rebase-plan.json"
ADOPTION = PREFIX + "-source-adoption-v3.json"
LOCK = "fingerprint-" + PREFIX + ".lock.json"


class M15648EvidenceError(ValueError):
    pass


def _sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _load(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise M15648EvidenceError("Missing or unsafe Chromium 156.48 evidence")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise M15648EvidenceError("Chromium 156.48 evidence must be an object")
    return value


def _paths(project_root: Path) -> tuple[Path, Path, Path]:
    runtime = project_root.resolve() / "runtime"
    return runtime / CONTRACT, runtime / PLAN, runtime / ADOPTION


def verify_contract(project_root: Path) -> dict[str, Any]:
    contract_path, plan_path, adoption_path = _paths(project_root)
    contract, plan, adoption = map(_load, (contract_path, plan_path, adoption_path))
    if contract.get("schemaVersion") != 1 or plan.get("schemaVersion") != 1:
        raise M15648EvidenceError("Unexpected Chromium 156.48 evidence schema")
    if (contract.get("targetChromiumVersion") != VERSION or
            plan.get("chromiumVersion") != VERSION or
            contract.get("targetArchitecture") != "arm64" or
            contract.get("sourceMode") != "official-chromium-stable-with-reviewed-neantik-patches" or
            contract.get("binaryBindingStatus") != "pending-new-build" or
            contract.get("releaseReady") is not False or
            plan.get("releaseReady") is not False or
            adoption.get("chromiumVersion") != VERSION):
        raise M15648EvidenceError("Chromium 156.48 contract identity/state mismatch")
    if contract.get("rebasePlanSHA256") != _sha(plan_path):
        raise M15648EvidenceError("Chromium 156.48 rebase plan digest mismatch")
    if contract.get("sourceAdoptionManifestSHA256") != _sha(adoption_path):
        raise M15648EvidenceError("Chromium 156.48 adoption manifest digest mismatch")
    if contract.get("sourcePatchSHA256") != adoption.get("patchSHA256"):
        raise M15648EvidenceError("Chromium 156.48 main patch digest mismatch")
    dev = adoption.get("devtoolsCompatibilityPatch")
    if not isinstance(dev, dict) or contract.get("devtoolsCompatibilityPatchSHA256") != dev.get("sha256"):
        raise M15648EvidenceError("Chromium 156.48 DevTools patch digest mismatch")
    v8 = adoption.get("v8CompatibilityPatch")
    if not isinstance(v8, dict) or contract.get("v8CompatibilityPatchSHA256") != v8.get("sha256"):
        raise M15648EvidenceError("Chromium 156.48 V8 patch digest mismatch")
    if contract.get("dependencyLockSHA256") != adoption.get("dependencyLockSHA256"):
        raise M15648EvidenceError("Chromium 156.48 dependency lock digest mismatch")
    if contract.get("buildArgsSHA256") != adoption.get("buildArgsSHA256"):
        raise M15648EvidenceError("Chromium 156.48 GN args digest mismatch")
    for key, rel, digest_key in (
        ("chromiumLicenseSHA256", "licenses/Chromium-LICENSE", None),
        ("securityBaselineSHA256", "security-baseline.json", None),
    ):
        if contract.get(key) != _sha(project_root.resolve() / "runtime" / rel):
            raise M15648EvidenceError("Chromium 156.48 packaged input digest mismatch: " + key)
    base = contract.get("officialChromiumBase")
    if not isinstance(base, dict) or base != plan.get("officialChromiumBase"):
        raise M15648EvidenceError("Chromium 156.48 official source identity mismatch")
    return contract


def verify_source_root(source_root: Path, project_root: Path) -> dict[str, Any]:
    contract = verify_contract(project_root)
    verifier_path = Path(__file__).resolve().with_name("verify-chromium-15648-source-adoption.py")
    spec = importlib.util.spec_from_file_location("neantik_chromium_15648_source_adoption", verifier_path)
    if spec is None or spec.loader is None:
        raise M15648EvidenceError("Chromium 156.48 source verifier could not be loaded")
    verifier_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier_module)
    verify_adoption = verifier_module.verify
    adoption = verify_adoption(project_root.resolve(), source_root)
    if adoption.get("officialCommit") != contract["officialChromiumBase"]["commit"]:
        raise M15648EvidenceError("Chromium 156.48 source commit does not match contract")
    args_path = source_root / "out/NeAntikStable156_48/args.gn"
    adoption_doc = _load(project_root.resolve() / "runtime" / ADOPTION)
    if not args_path.is_file() or args_path.is_symlink() or _sha(args_path) != adoption_doc["buildArgsSHA256"]:
        raise M15648EvidenceError("Chromium 156.48 exact GN args mismatch")
    return {"contract": contract, "adoption": adoption_doc, "sourceVerification": adoption}


def build_provenance(source_root: Path, project_root: Path) -> dict[str, Any]:
    if not source_root.is_absolute() or source_root.is_symlink() or not source_root.is_dir():
        raise M15648EvidenceError("Chromium source root must be an absolute regular directory")
    verified = verify_source_root(source_root.resolve(), project_root)
    contract, adoption, source = verified["contract"], verified["adoption"], verified["sourceVerification"]
    return {
        "schemaVersion": 1,
        "status": "source-qualified",
        "sourceMode": "official-chromium-stable-with-reviewed-neantik-patches",
        "targetChromiumVersion": VERSION,
        "targetArchitecture": "arm64",
        "officialChromiumBase": contract["officialChromiumBase"],
        "sourceContractSHA256": _sha(project_root.resolve() / "runtime" / CONTRACT),
        "sourceAdoptionManifestSHA256": _sha(project_root.resolve() / "runtime" / ADOPTION),
        "sourcePatchSHA256": adoption["patchSHA256"],
        "devtoolsCompatibilityPatchSHA256": adoption["devtoolsCompatibilityPatch"]["sha256"],
        "v8CompatibilityPatchSHA256": adoption["v8CompatibilityPatch"]["sha256"],
        "dependencyLockSHA256": adoption["dependencyLockSHA256"],
        "dependencyGitCheckoutCount": source["dependencyGitCheckoutCount"],
        "buildArgsSHA256": adoption["buildArgsSHA256"],
        "sourceChecks": {
            "officialCommitTree": "verified",
            "versionFile": "verified",
            "pinnedDependencies": "verified",
            "mainPatchApplied": "verified",
            "devtoolsPatchApplied": "verified",
            "v8CompatibilityPatchApplied": "verified",
            "buildArgs": "verified",
        },
        "binaryBinding": {"status": "pending-new-build", "requiredEvidence": "schema-3-runtime-report"},
    }


def verify_provenance(document: dict[str, Any], project_root: Path) -> None:
    contract = verify_contract(project_root)
    adoption = _load(project_root.resolve() / "runtime" / ADOPTION)
    expected = {
        "schemaVersion": 1,
        "status": "source-qualified",
        "sourceMode": "official-chromium-stable-with-reviewed-neantik-patches",
        "targetChromiumVersion": VERSION,
        "targetArchitecture": "arm64",
        "officialChromiumBase": contract["officialChromiumBase"],
        "sourceContractSHA256": _sha(project_root.resolve() / "runtime" / CONTRACT),
        "sourceAdoptionManifestSHA256": _sha(project_root.resolve() / "runtime" / ADOPTION),
        "sourcePatchSHA256": adoption["patchSHA256"],
        "devtoolsCompatibilityPatchSHA256": adoption["devtoolsCompatibilityPatch"]["sha256"],
        "v8CompatibilityPatchSHA256": adoption["v8CompatibilityPatch"]["sha256"],
        "dependencyLockSHA256": adoption["dependencyLockSHA256"],
        "dependencyGitCheckoutCount": adoption["dependencyGitCheckoutCount"],
        "buildArgsSHA256": adoption["buildArgsSHA256"],
        "sourceChecks": {"officialCommitTree":"verified","versionFile":"verified","pinnedDependencies":"verified","mainPatchApplied":"verified","devtoolsPatchApplied":"verified","v8CompatibilityPatchApplied":"verified","buildArgs":"verified"},
        "binaryBinding": {"status":"pending-new-build","requiredEvidence":"schema-3-runtime-report"},
    }
    if document != expected:
        raise M15648EvidenceError("Chromium 156.48 source provenance differs from verified pins")


def expected_lock(provenance_path: Path, project_root: Path) -> dict[str, Any]:
    provenance = _load(provenance_path)
    verify_provenance(provenance, project_root)
    contract_path = project_root.resolve() / "runtime" / CONTRACT
    contract = verify_contract(project_root)
    base = contract["officialChromiumBase"]
    return {
        "schemaVersion": 4,
        "status": "source-qualified",
        "targetArchitecture": "arm64",
        "sourceContract": "runtime/" + CONTRACT,
        "sourceContractSHA256": _sha(contract_path),
        "sourceProvenanceSHA256": _sha(provenance_path),
        "sourceAdoptionManifestSHA256": contract["sourceAdoptionManifestSHA256"],
        "fingerprintChromium": {
            "repository": base["repository"], "tag": base["tag"], "commit": base["commit"],
            "tree": base["tree"], "chromiumVersion": VERSION,
            "licenseSHA256": contract["chromiumLicenseSHA256"],
        },
        "ownedInputs": {
            "sourcePatchSHA256": contract["sourcePatchSHA256"],
            "devtoolsCompatibilityPatchSHA256": contract["devtoolsCompatibilityPatchSHA256"],
            "v8CompatibilityPatchSHA256": contract["v8CompatibilityPatchSHA256"],
            "dependencyLockSHA256": contract["dependencyLockSHA256"],
            "buildArgsSHA256": contract["buildArgsSHA256"],
        },
        "ownedManifests": {
            "neantikPatchSeriesSHA256": _sha(project_root.resolve() / "runtime/nevision-patches/series.json"),
            "appleDeviceTuplesSHA256": _sha(project_root.resolve() / "runtime/apple-device-tuples.json"),
            "securityBaselineSHA256": _sha(project_root.resolve() / "runtime/security-baseline.json"),
        },
        "binaryBinding": {"status":"not-attested-by-this-document","requiredEvidence":"schema-3-runtime-report",
                          "policy":"This source-only candidate lock makes no binary, build, notarization, publication, or runtime-result claim."},
    }


def verify_lock(lock: dict[str, Any], provenance_path: Path, project_root: Path) -> dict[str, Any]:
    expected = expected_lock(provenance_path, project_root)
    if lock != expected:
        raise M15648EvidenceError("Chromium 156.48 candidate lock is stale or mutated")
    return lock
