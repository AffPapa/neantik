#!/usr/bin/env python3
"""Pinned Chromium 156.0.8078.80 source/build evidence.

Pre-build verification proves only source inputs. Provenance and candidate
locks are deliberately unavailable until the exact active Ninja run has an
exit-zero receipt and the emitted browser/framework bytes are hashed.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import subprocess
from pathlib import Path
from typing import Any

from runtime_historical_baseline import bound_baseline_path

VERSION = "156.0.8078.80"
PREFIX = "chromium-15680"
CONTRACT = PREFIX + "-source-contract.json"
PLAN = PREFIX + "-rebase-plan.json"
ADOPTION = PREFIX + "-source-adoption-v1.json"
LOCK = "fingerprint-" + PREFIX + ".lock.json"
REPOSITORY = "https://chromium.googlesource.com/chromium/src.git"
COMMIT = "fb096c0011f9d50f0a264a9376420cdea9c421e3"
TREE = "9daca4c0f1670a0ead9a94888c1bfe4ace733f4d"
BUILD_DIRECTORY = "out/NeAntikStable156_48"
HEX = re.compile(r"^[0-9a-f]{64}$")


class M15680EvidenceError(ValueError):
    pass


def _sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def _load(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise M15680EvidenceError(f"Missing or unsafe {label}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise M15680EvidenceError(f"Invalid JSON in {label}") from error
    if not isinstance(value, dict):
        raise M15680EvidenceError(f"{label} must be an object")
    return value


def verify_contract(project_root: Path) -> dict[str, Any]:
    root = project_root.resolve()
    runtime = root / "runtime"
    cp, pp, ap = runtime / CONTRACT, runtime / PLAN, runtime / ADOPTION
    contract, plan, adoption = (_load(cp, "Chromium 156.80 contract"),
                                _load(pp, "Chromium 156.80 rebase plan"),
                                _load(ap, "Chromium 156.80 adoption manifest"))
    if (contract.get("schemaVersion") != 1 or plan.get("schemaVersion") != 1 or
            adoption.get("schemaVersion") != 1 or
            contract.get("targetChromiumVersion") != VERSION or
            plan.get("chromiumVersion") != VERSION or adoption.get("chromiumVersion") != VERSION or
            contract.get("targetArchitecture") != "arm64" or
            contract.get("releaseReady") is not False or plan.get("releaseReady") is not False or
            adoption.get("releaseReady") is not False or
            contract.get("sourceMode") != "official-chromium-stable-with-reviewed-neantik-patches" or
            contract.get("officialChromiumBase") != plan.get("officialChromiumBase") or
            plan["officialChromiumBase"] != {"repository": REPOSITORY, "tag": VERSION,
                                                   "commit": COMMIT, "tree": TREE}):
        raise M15680EvidenceError("Chromium 156.80 contract identity/state mismatch")
    for field, file_path in (("rebasePlanSHA256", pp),
                             ("sourceAdoptionManifestSHA256", ap)):
        expected = contract.get(field)
        if not isinstance(expected, str) or not HEX.fullmatch(expected) or _sha(file_path) != expected:
            raise M15680EvidenceError(f"Chromium 156.80 contract digest mismatch: {field}")
    if plan.get("sourceInputs") != {
            "patchSHA256": adoption.get("patchSHA256"),
            "devtoolsCompatibilityPatchSHA256": adoption.get("devtoolsCompatibilityPatch", {}).get("sha256"),
            "v8CompatibilityPatchSHA256": adoption.get("v8CompatibilityPatch", {}).get("sha256"),
            "dependencyLockSHA256": adoption.get("dependencyLockSHA256"),
            "depsFileSHA256": adoption.get("depsFileSHA256"),
            "gclientConfigSHA256": adoption.get("gclientConfigSHA256"),
            "gclientEntriesSHA256": adoption.get("gclientEntriesSHA256"),
            "gcsEntriesSHA256": adoption.get("gcsEntriesSHA256"),
            "buildArgsSHA256": adoption.get("buildArgsSHA256"),
            "dependencyGitCheckoutCount": 150, "nonGitInputCount": 89}:
        raise M15680EvidenceError("Chromium 156.80 rebase plan does not match adoption pins")
    expected_receipts = {
        "v900ReceiptSHA256": adoption.get("upstreamReceipts", {}).get("v900SHA256"),
        "v904ReceiptSHA256": adoption.get("upstreamReceipts", {}).get("v904SHA256"),
        "v907ManifestSHA256": adoption.get("upstreamReceipts", {}).get("v907ManifestSHA256"),
        "v921GNAcceptanceReceiptSHA256": adoption.get("upstreamReceipts", {}).get("v921SHA256"),
        "v922BuildProgressReceiptSHA256": adoption.get("upstreamReceipts", {}).get("v922SHA256"),
        "v923ContractGapReceiptSHA256": adoption.get("upstreamReceipts", {}).get("v923SHA256"),
    }
    if plan.get("sourceEvidence") != expected_receipts:
        raise M15680EvidenceError("Chromium 156.80 rebase plan receipt links differ from adopted evidence")
    if adoption.get("sourceOffer") != {
            "manifestSHA256": "8e3b1f53ebd6b041195c216a01d4a8a5a1bf2d5fae1b3108f253e5bce9689951",
            "routeSHA256": "4a27d42f92fe4f5d5300fda01c6dd39bdc1fe5892522d99098d1814ef9c27410",
            "componentCount": 894}:
        raise M15680EvidenceError("Chromium 156.80 source-offer binding differs from V907")
    for rel, expected in (
            ("chromium-15680-neantik.patch", contract.get("sourcePatchSHA256")),
            ("chromium-15680-devtools-typescript6.patch", contract.get("devtoolsCompatibilityPatchSHA256")),
            ("chromium-15680-v8-scope-iterator-compat.patch", contract.get("v8CompatibilityPatchSHA256")),
            ("chromium-15680-deps-lock.json", contract.get("dependencyLockSHA256")),
            ("chromium-15680-DEPS", contract.get("depsFileSHA256")),
            ("chromium-15680-args.gn", contract.get("buildArgsSHA256")),
            ("chromium-15680-gclient", contract.get("gclientConfigSHA256")),
            ("chromium-15680-gclient_entries", contract.get("gclientEntriesSHA256")),
            ("chromium-15680-gcs_entries", contract.get("gcsEntriesSHA256")),
            ("licenses/Chromium-LICENSE", contract.get("chromiumLicenseSHA256"))):
        path = runtime / rel
        if not isinstance(expected, str) or not HEX.fullmatch(expected) or path.is_symlink() or not path.is_file() or _sha(path) != expected:
            raise M15680EvidenceError(f"Chromium 156.80 pinned file mismatch: {rel}")
    try:
        bound_baseline_path(runtime, contract.get("securityBaselineSHA256"))
    except ValueError as error:
        raise M15680EvidenceError("Chromium 156.80 pinned file mismatch: security-baseline.json") from error
    if contract.get("sourceAdoptionManifestSHA256") != _sha(ap):
        raise M15680EvidenceError("Chromium 156.80 source-adoption manifest hash is stale")
    if (contract.get("sourcePatchSHA256") != adoption.get("patchSHA256") or
            contract.get("devtoolsCompatibilityPatchSHA256") != adoption.get("devtoolsCompatibilityPatch", {}).get("sha256") or
            contract.get("v8CompatibilityPatchSHA256") != adoption.get("v8CompatibilityPatch", {}).get("sha256") or
            contract.get("dependencyLockSHA256") != adoption.get("dependencyLockSHA256") or
            contract.get("depsFileSHA256") != adoption.get("depsFileSHA256") or
            contract.get("buildArgsSHA256") != adoption.get("buildArgsSHA256")):
        raise M15680EvidenceError("Chromium 156.80 contract and adoption pins differ")
    if contract.get("binaryBindingStatus") == "pending-build":
        if (contract.get("status") != "source-pins-verified-build-pending" or
                contract.get("buildEvidenceSHA256") is not None or
                adoption.get("buildEvidenceSHA256") is not None or
                contract.get("buildEvidenceStatus") != "pending-active-Ninja-session"):
            raise M15680EvidenceError("Chromium 156.80 pre-build state is inconsistent")
    elif contract.get("binaryBindingStatus") == "pending-runtime-report":
        evidence_path = runtime / "chromium-15680-build-evidence.json"
        build_evidence = _load(evidence_path, "Chromium 156.80 build evidence")
        evidence_sha = _sha(evidence_path)
        if (contract.get("status") != "build-complete-runtime-report-pending" or
                contract.get("buildEvidenceStatus") != "completed-build-verified-runtime-report-pending" or
                contract.get("buildEvidenceSHA256") != evidence_sha or
                adoption.get("buildEvidenceSHA256") != evidence_sha or
                build_evidence.get("status") != "chromium-source-build-succeeded-unqualified" or
                build_evidence.get("chromiumVersion") != VERSION or
                build_evidence.get("officialCommit") != COMMIT or
                build_evidence.get("officialTree") != TREE or
                build_evidence.get("ninjaTarget") != "chrome" or
                build_evidence.get("ninjaExitCode") != 0 or
                build_evidence.get("releaseReady") is not False):
            raise M15680EvidenceError("Chromium 156.80 completed build evidence is inconsistent")
    else:
        raise M15680EvidenceError("Chromium 156.80 contract has an unknown build state")
    from chromium_15680_portable_crc import verify as verify_portable_crc
    verify_portable_crc(root, contract)
    return contract


def verify_source_root(source_root: Path, project_root: Path) -> dict[str, Any]:
    contract = verify_contract(project_root)
    if source_root.is_symlink() or not source_root.is_absolute() or not source_root.is_dir():
        raise M15680EvidenceError("Chromium 156.80 source root must be absolute and non-symlinked")
    verifier_path = Path(__file__).with_name("verify-chromium-15648-source-adoption.py")
    spec = importlib.util.spec_from_file_location("neantik_chromium_source_adoption", verifier_path)
    if spec is None or spec.loader is None:
        raise M15680EvidenceError("Chromium 156.80 adoption verifier is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = module.verify(project_root.resolve(), source_root.resolve(), ADOPTION)
    from chromium_15680_portable_crc import verify_source as verify_portable_source
    verify_portable_source(project_root.resolve(), contract, source_root.resolve())
    adoption = _load(project_root.resolve() / "runtime" / ADOPTION, "Chromium 156.80 adoption manifest")
    return {"contract": contract, "adoption": adoption, "sourceVerification": result}


def build_provenance(source_root: Path, project_root: Path) -> dict[str, Any]:
    verified = verify_source_root(source_root, project_root)
    source = verified["sourceVerification"]
    if source.get("buildEvidenceStatus") != "verified":
        raise M15680EvidenceError(
            "Chromium 156.80 build evidence is pending; export is blocked until the completed Ninja run is captured"
        )
    contract = verified["contract"]
    adoption = verified["adoption"]
    return _expected_provenance(contract, adoption, verified["sourceVerification"], project_root)


def _expected_provenance(contract: dict[str, Any], adoption: dict[str, Any], source: dict[str, Any],
                         project_root: Path) -> dict[str, Any]:
    if source.get("buildEvidenceStatus") != "verified":
        raise M15680EvidenceError(
            "Chromium 156.80 build evidence is pending; export is blocked until the completed Ninja run is captured"
        )
    result = {
        "schemaVersion": 1, "status": "source-qualified",
        "sourceMode": contract["sourceMode"], "targetChromiumVersion": VERSION,
        "targetArchitecture": "arm64", "officialChromiumBase": contract["officialChromiumBase"],
        "sourceContractSHA256": _sha(project_root.resolve() / "runtime" / CONTRACT),
        "sourceAdoptionManifestSHA256": _sha(project_root.resolve() / "runtime" / ADOPTION),
        "sourcePatchSHA256": adoption["patchSHA256"],
        "devtoolsCompatibilityPatchSHA256": adoption["devtoolsCompatibilityPatch"]["sha256"],
        "v8CompatibilityPatchSHA256": adoption["v8CompatibilityPatch"]["sha256"],
        "dependencyLockSHA256": adoption["dependencyLockSHA256"],
        "depsFileSHA256": adoption["depsFileSHA256"],
        "dependencyGitCheckoutCount": source["dependencyGitCheckoutCount"],
        "buildArgsSHA256": adoption["buildArgsSHA256"],
        "sourceChecks": {"officialCommitTree": "verified", "versionFile": "verified",
                          "pinnedDependencies": "verified", "mainPatchApplied": "verified",
                          "devtoolsPatchApplied": "verified", "v8CompatibilityPatchApplied": "verified",
                          "buildArgs": "verified", "buildEvidence": "verified"},
        "binaryBinding": {"status": "pending-runtime-report", "requiredEvidence": "schema-3-runtime-report"},
        "releaseReady": False,
    }
    if "portableCRC" in contract:
        result["portableCRC"] = contract["portableCRC"]
        result["sourceChecks"]["portableCRC"] = "overlay-and-derived-build-evidence-verified"
    return result


def verify_provenance(document: dict[str, Any], project_root: Path) -> None:
    contract = verify_contract(project_root)
    runtime = project_root.resolve() / "runtime"
    adoption = _load(runtime / ADOPTION, "Chromium 156.80 adoption manifest")
    evidence_path = runtime / "chromium-15680-build-evidence.json"
    if adoption.get("buildEvidenceSHA256") is None or not evidence_path.is_file():
        raise M15680EvidenceError("Chromium 156.80 provenance cannot be accepted before build evidence")
    _load(evidence_path, "Chromium 156.80 build evidence")
    source_result = {"buildEvidenceStatus": "verified",
                     "dependencyGitCheckoutCount": adoption["dependencyGitCheckoutCount"]}
    expected = _expected_provenance(contract, adoption, source_result, project_root)
    if document != expected:
        raise M15680EvidenceError("Chromium 156.80 source provenance differs from pinned evidence")


def expected_lock(provenance_path: Path, project_root: Path) -> dict[str, Any]:
    provenance = _load(provenance_path, "Chromium 156.80 provenance")
    verify_provenance(provenance, project_root)
    contract = verify_contract(project_root)
    if provenance.get("binaryBinding", {}).get("status") != "pending-runtime-report":
        raise M15680EvidenceError("Chromium 156.80 source lock cannot attest runtime binaries")
    base = contract["officialChromiumBase"]
    result = {
        "schemaVersion": 4, "status": "source-qualified", "targetArchitecture": "arm64",
        "sourceContract": "runtime/" + CONTRACT,
        "sourceContractSHA256": _sha(project_root.resolve() / "runtime" / CONTRACT),
        "sourceProvenanceSHA256": _sha(provenance_path),
        "sourceAdoptionManifestSHA256": contract["sourceAdoptionManifestSHA256"],
        "fingerprintChromium": {"repository": base["repository"], "tag": base["tag"],
                                "commit": base["commit"], "tree": base["tree"],
                                "chromiumVersion": VERSION,
                                "licenseSHA256": contract["chromiumLicenseSHA256"]},
        "ownedInputs": {"sourcePatchSHA256": contract["sourcePatchSHA256"],
                         "devtoolsCompatibilityPatchSHA256": contract["devtoolsCompatibilityPatchSHA256"],
                         "v8CompatibilityPatchSHA256": contract["v8CompatibilityPatchSHA256"],
                         "dependencyLockSHA256": contract["dependencyLockSHA256"],
            "depsFileSHA256": contract["depsFileSHA256"],
                         "buildArgsSHA256": contract["buildArgsSHA256"]},
        "ownedManifests": {"neantikPatchSeriesSHA256": _sha(project_root.resolve() / "runtime/nevision-patches/series.json"),
                           "appleDeviceTuplesSHA256": _sha(project_root.resolve() / "runtime/apple-device-tuples.json"),
                           "securityBaselineSHA256": contract["securityBaselineSHA256"]},
        "binaryBinding": {"status": "not-attested-by-this-document", "requiredEvidence": "schema-3-runtime-report",
                          "policy": "This source-only lock makes no binary, runtime, notarization, or publication claim."},
    }
    if "portableCRC" in contract:
        result["ownedInputs"]["portableCrcManifestSHA256"] = contract["portableCRC"]["sha256"]
    return result


def verify_lock(lock: dict[str, Any], provenance_path: Path, project_root: Path) -> dict[str, Any]:
    if lock != expected_lock(provenance_path, project_root):
        raise M15680EvidenceError("Chromium 156.80 source candidate lock is stale or mutated")
    return lock
