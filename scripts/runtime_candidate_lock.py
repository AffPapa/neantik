#!/usr/bin/env python3
"""Deterministic source-qualified lock for an unpromoted Chromium candidate."""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

from runtime_source_provenance import (
    PROJECT_ROOT,
    SourceProvenanceError,
    ensure_no_stale_markers,
    load_object,
    sha256_file,
    verify_contract,
    verify_document,
)


DEFAULT_CONTRACT = PROJECT_ROOT / "runtime" / "chromium-152-source-contract.json"
DEFAULT_PATCH_MANIFEST = PROJECT_ROOT / "runtime" / "nevision-patches" / "series.json"
DEFAULT_DEVICE_TUPLES = PROJECT_ROOT / "runtime" / "apple-device-tuples.json"
DEFAULT_SECURITY_BASELINE = PROJECT_ROOT / "runtime" / "security-baseline.json"
PUBLISHED_LOCK = PROJECT_ROOT / "runtime" / "fingerprint-chromium.lock.json"


def _reject_local_paths(value: Any, label: str = "candidate lock") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            _reject_local_paths(child, f"{label}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            _reject_local_paths(child, f"{label}[{index}]")
        return
    if not isinstance(value, str):
        return
    if (
        value.startswith("/")
        or value.startswith("file:")
        or "/Users/" in value
        or "/private/tmp/" in value
        or "/var/folders/" in value
    ):
        raise SourceProvenanceError(f"{label} contains a local absolute path")


def expected_candidate_lock(
    provenance_path: Path,
    *,
    project_root: Path = PROJECT_ROOT,
    contract_path: Path | None = None,
    rebase_plan_path: Path | None = None,
) -> dict[str, Any]:
    project_root = project_root.resolve()
    contract_path = contract_path or project_root / "runtime" / "chromium-152-source-contract.json"
    rebase_plan_path = rebase_plan_path or project_root / "runtime" / "chromium-152-rebase-plan.json"
    provenance = load_object(
        provenance_path,
        "emitted Chromium source provenance",
    )
    verify_document(
        provenance,
        project_root=project_root,
        contract_path=contract_path,
        rebase_plan_path=rebase_plan_path,
    )
    contract = verify_contract(
        project_root=project_root,
        contract_path=contract_path,
        rebase_plan_path=rebase_plan_path,
    )
    contract_sha = sha256_file(contract_path)
    if provenance.get("contractSHA256") != contract_sha:
        raise SourceProvenanceError(
            "Source provenance is not bound to the checked source contract"
        )
    official = contract["officialChromiumBase"]
    gclient = contract["sourceMode"] == "gclient"
    patch_manifest = project_root / "runtime/nevision-patches" / ("series-153.json" if gclient else "series.json")
    if gclient:
        manifest = load_object(patch_manifest, "gclient owned patch manifest")
        if manifest.get("targetChromiumVersion") != contract["targetChromiumVersion"]:
            raise SourceProvenanceError("Owned patch manifest differs from gclient Chromium version")
        relative_manifest = patch_manifest.relative_to(project_root).as_posix()
        if contract['ownedInputs'].get(relative_manifest) != sha256_file(patch_manifest):
            raise SourceProvenanceError('Gclient patch manifest must be bound to the source contract')
    candidate = {
        "schemaVersion": 5 if gclient else 4,
        "status": "source-qualified",
        "targetArchitecture": "arm64",
        "sourceContractSHA256": contract_sha,
        "sourceProvenanceSHA256": sha256_file(provenance_path),
        "fingerprintChromium": {
            "repository": official["repository"],
            "tag": official["tag"],
            "commit": official["commit"],
            "tree": official["tree"],
            "chromiumVersion": contract["targetChromiumVersion"],
            "licenseSHA256": official["licenseSHA256"],
        },
        "ownedInputs": copy.deepcopy(contract["ownedInputs"]),
        "ownedManifests": {
            "neantikPatchSeriesSHA256": sha256_file(
                patch_manifest
            ),
            "appleDeviceTuplesSHA256": sha256_file(
                project_root / "runtime" / "apple-device-tuples.json"
            ),
            "securityBaselineSHA256": sha256_file(
                project_root / "runtime" / "security-baseline.json"
            ),
        },
        "binaryBinding": {
            "status": "not-attested-by-this-document",
            "requiredEvidence": "schema-3-runtime-report",
            "policy": (
                "This source-only candidate lock makes no binary, build, "
                "notarization, publication, or runtime-result claim."
            ),
        },
    }
    if gclient:
        candidate.update({"sourceMode": "gclient",
                          "inputBundle": copy.deepcopy(contract["inputBundle"]),
                          "buildToolFiles": copy.deepcopy(contract["buildToolFiles"])})
    else:
        candidate["fingerprintChromium"]["liteArchive"] = copy.deepcopy(official["liteArchive"])
        candidate["macPackaging"] = copy.deepcopy(contract["macPackaging"])
        candidate["macPackaging"]["effectiveCommonCommit"] = provenance["macPackaging"]["effectiveCommonCommit"]
        candidate["commonChromium"] = copy.deepcopy(contract["commonChromium"])
    ensure_no_stale_markers(candidate, "new-candidate runtime lock")
    _reject_local_paths(candidate)
    return candidate


def verify_candidate_lock(
    candidate_path: Path,
    provenance_path: Path,
    *,
    project_root: Path = PROJECT_ROOT,
    contract_path: Path | None = None,
    rebase_plan_path: Path | None = None,
) -> dict[str, Any]:
    if not candidate_path.is_absolute() or not provenance_path.is_absolute():
        raise SourceProvenanceError(
            "Candidate lock and source provenance paths must be absolute"
        )
    if candidate_path.is_symlink() or provenance_path.is_symlink():
        raise SourceProvenanceError(
            "Candidate lock and source provenance must not be symlinks"
        )
    actual = load_object(candidate_path, "new-candidate runtime lock")
    ensure_no_stale_markers(actual, "new-candidate runtime lock")
    _reject_local_paths(actual)
    expected = expected_candidate_lock(
        provenance_path,
        project_root=project_root,
        contract_path=contract_path,
        rebase_plan_path=rebase_plan_path,
    )
    if actual != expected:
        differing = next(
            (
                key
                for key in sorted({*actual, *expected})
                if actual.get(key) != expected.get(key)
            ),
            "<unknown>",
        )
        raise SourceProvenanceError(
            f"New-candidate runtime lock is stale or mutated: {differing}"
        )
    return actual


def refuse_published_lock_output(
    output: Path,
    *,
    project_root: Path = PROJECT_ROOT,
) -> None:
    published = (
        project_root.resolve()
        / "runtime"
        / "fingerprint-chromium.lock.json"
    )
    if output.resolve() == published.resolve():
        raise SourceProvenanceError(
            "Candidate exporter must never overwrite the published runtime lock"
        )
