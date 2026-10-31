"""Source and candidate evidence for the Chromium 156.0.8078.74 port."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
from typing import Any

from runtime_historical_baseline import bound_baseline_path

VERSION = "156.0.8078.74"
PREFIX = "chromium-15674"
CONTRACT = PREFIX + "-source-contract.json"
PLAN = PREFIX + "-rebase-plan.json"
ADOPTION = PREFIX + "-source-adoption-v1.json"
LOCK = "fingerprint-" + PREFIX + ".lock.json"


class M15674EvidenceError(ValueError):
    pass


def _sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise M15674EvidenceError("Missing or unsafe Chromium 156.74 evidence")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise M15674EvidenceError("Chromium 156.74 evidence must be an object")
    return value


def verify_contract(project_root: Path) -> dict[str, Any]:
    root = project_root.resolve()
    runtime = root / "runtime"
    contract_path, plan_path, adoption_path = (
        runtime / CONTRACT,
        runtime / PLAN,
        runtime / ADOPTION,
    )
    contract, plan, adoption = map(_load, (contract_path, plan_path, adoption_path))
    if (
        contract.get("schemaVersion") != 1
        or plan.get("schemaVersion") != 1
        or contract.get("targetChromiumVersion") != VERSION
        or plan.get("chromiumVersion") != VERSION
        or contract.get("targetArchitecture") != "arm64"
        or contract.get("sourceMode") != "official-chromium-stable-with-reviewed-neantik-patches"
        or contract.get("binaryBindingStatus") != "pending-runtime-report"
        or contract.get("releaseReady") is not False
        or plan.get("releaseReady") is not False
        or adoption.get("chromiumVersion") != VERSION
        or adoption.get("releaseReady") is not False
    ):
        raise M15674EvidenceError("Chromium 156.74 contract identity/state mismatch")
    if (
        contract.get("rebasePlanSHA256") != _sha(plan_path)
        or contract.get("sourceAdoptionManifestSHA256") != _sha(adoption_path)
        or contract.get("sourcePatchSHA256") != adoption.get("patchSHA256")
        or contract.get("dependencyLockSHA256") != adoption.get("dependencyLockSHA256")
        or contract.get("buildArgsSHA256") != adoption.get("buildArgsSHA256")
        or contract.get("buildEvidenceSHA256") != adoption.get("buildEvidenceSHA256")
    ):
        raise M15674EvidenceError("Chromium 156.74 source evidence digest mismatch")
    devtools = adoption.get("devtoolsCompatibilityPatch")
    v8 = adoption.get("v8CompatibilityPatch")
    if (
        not isinstance(devtools, dict)
        or contract.get("devtoolsCompatibilityPatchSHA256") != devtools.get("sha256")
        or not isinstance(v8, dict)
        or contract.get("v8CompatibilityPatchSHA256") != v8.get("sha256")
    ):
        raise M15674EvidenceError("Chromium 156.74 compatibility patch digest mismatch")
    for field, relative in (
        ("chromiumLicenseSHA256", "licenses/Chromium-LICENSE"),
        ("securityBaselineSHA256", "security-baseline.json"),
    ):
        try:
            path = (bound_baseline_path(runtime, contract.get(field))
                    if field == "securityBaselineSHA256" else runtime / relative)
        except ValueError as error:
            raise M15674EvidenceError("Chromium 156.74 packaged input digest mismatch: " + field) from error
        if contract.get(field) != _sha(path):
            raise M15674EvidenceError("Chromium 156.74 packaged input digest mismatch: " + field)
    base = contract.get("officialChromiumBase")
    if (
        not isinstance(base, dict)
        or base != plan.get("officialChromiumBase")
        or base.get("tag") != VERSION
        or base.get("commit") != "d331de35ca8ab1358c7a17e4bd41627d55eaef51"
    ):
        raise M15674EvidenceError("Chromium 156.74 official source identity mismatch")
    return contract


def verify_source_root(source_root: Path, project_root: Path) -> dict[str, Any]:
    contract = verify_contract(project_root)
    if source_root.is_symlink() or not source_root.is_absolute() or not source_root.is_dir():
        raise M15674EvidenceError("Chromium source root must be absolute and non-symlinked")
    source_root = source_root.resolve()
    verifier_path = Path(__file__).resolve().with_name("verify-chromium-15648-source-adoption.py")
    spec = importlib.util.spec_from_file_location("neantik_chromium_source_adoption", verifier_path)
    if spec is None or spec.loader is None:
        raise M15674EvidenceError("Chromium source-adoption verifier could not be loaded")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    adoption_result = verifier.verify(project_root.resolve(), source_root, ADOPTION)
    if adoption_result.get("officialCommit") != contract["officialChromiumBase"]["commit"]:
        raise M15674EvidenceError("Chromium 156.74 source commit differs from contract")
    adoption_doc = _load(project_root.resolve() / "runtime" / ADOPTION)
    output_dir = adoption_doc.get("buildOutputDirectory")
    args_path = source_root / output_dir / "args.gn" if isinstance(output_dir, str) else source_root / "out/invalid/args.gn"
    if args_path.is_symlink() or not args_path.is_file() or _sha(args_path) != adoption_doc.get("buildArgsSHA256"):
        raise M15674EvidenceError("Chromium 156.74 exact GN args mismatch")
    return {"contract": contract, "adoption": adoption_doc, "sourceVerification": adoption_result}


def build_provenance(source_root: Path, project_root: Path) -> dict[str, Any]:
    verified = verify_source_root(source_root, project_root)
    contract = verified["contract"]
    adoption = verified["adoption"]
    source = verified["sourceVerification"]
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
        "binaryBinding": {"status": "pending-runtime-report", "requiredEvidence": "schema-3-runtime-report"},
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
        "sourceChecks": {
            "officialCommitTree": "verified",
            "versionFile": "verified",
            "pinnedDependencies": "verified",
            "mainPatchApplied": "verified",
            "devtoolsPatchApplied": "verified",
            "v8CompatibilityPatchApplied": "verified",
            "buildArgs": "verified",
        },
        "binaryBinding": {"status": "pending-runtime-report", "requiredEvidence": "schema-3-runtime-report"},
    }
    if document != expected:
        raise M15674EvidenceError("Chromium 156.74 source provenance differs from verified pins")


def expected_lock(provenance_path: Path, project_root: Path) -> dict[str, Any]:
    provenance = _load(provenance_path)
    verify_provenance(provenance, project_root)
    contract = verify_contract(project_root)
    contract_path = project_root.resolve() / "runtime" / CONTRACT
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
            "repository": base["repository"],
            "tag": base["tag"],
            "commit": base["commit"],
            "tree": base["tree"],
            "chromiumVersion": VERSION,
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
            "securityBaselineSHA256": _sha(bound_baseline_path(
                project_root.resolve() / "runtime", contract.get("securityBaselineSHA256"))),
        },
        "binaryBinding": {
            "status": "not-attested-by-this-document",
            "requiredEvidence": "schema-3-runtime-report",
            "policy": "This source-only candidate lock makes no notarization, publication, or runtime qualification claim.",
        },
    }


def verify_lock(lock: dict[str, Any], provenance_path: Path, project_root: Path) -> dict[str, Any]:
    if lock != expected_lock(provenance_path, project_root):
        raise M15674EvidenceError("Chromium 156.74 candidate lock is stale or mutated")
    return lock
