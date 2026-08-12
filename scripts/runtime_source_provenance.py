#!/usr/bin/env python3
"""Fail-closed Chromium source provenance helpers.

This module deliberately proves source inputs only. A runtime binary is bound
to this evidence only when a new runtime verification report records the
emitted document's SHA-256.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = PROJECT_ROOT / "runtime" / "chromium-151-source-contract.json"
DEFAULT_REBASE_PLAN = PROJECT_ROOT / "runtime" / "chromium-151-rebase-plan.json"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_RE = re.compile(r"^[0-9a-f]{40}$")
STALE_PROVENANCE_MARKERS = (
    "6bbb0dbdeae887af207c75c9e5173cceddbd381b",
    "144.0.7559.96",
)


class SourceProvenanceError(ValueError):
    pass


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SourceProvenanceError(f"Cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise SourceProvenanceError(f"{label} must contain a JSON object")
    return value


def require_text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise SourceProvenanceError(f"{label} must be a non-empty string")
    return value


def require_sha256(value: object, label: str) -> str:
    text = require_text(value, label)
    if not SHA256_RE.fullmatch(text):
        raise SourceProvenanceError(f"{label} must be a lowercase SHA-256")
    return text


def require_git_object(value: object, label: str) -> str:
    text = require_text(value, label)
    if not GIT_OBJECT_RE.fullmatch(text):
        raise SourceProvenanceError(f"{label} must be a lowercase Git object id")
    return text


def ensure_no_stale_markers(value: object, label: str) -> None:
    serialized = json.dumps(value, sort_keys=True, ensure_ascii=True)
    marker = next(
        (candidate for candidate in STALE_PROVENANCE_MARKERS if candidate in serialized),
        None,
    )
    if marker is not None:
        raise SourceProvenanceError(
            f"{label} contains stale Chromium 144 provenance marker {marker}"
        )


def git_output(repository: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise SourceProvenanceError(
            f"Git verification failed in {repository}: {detail}"
        )
    return completed.stdout.strip()


def git_object_sha256(repository: Path, object_path: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repository), "show", object_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise SourceProvenanceError(
            f"Cannot read locked Git object {object_path} in {repository}"
        )
    return sha256_bytes(completed.stdout)


def chromium_version(source_root: Path) -> str:
    version_path = source_root / "chrome" / "VERSION"
    try:
        pairs = dict(
            line.split("=", 1)
            for line in version_path.read_text(encoding="utf-8").splitlines()
            if "=" in line
        )
        return ".".join(
            pairs[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH")
        )
    except (OSError, KeyError, ValueError) as error:
        raise SourceProvenanceError(
            f"Cannot read complete Chromium version from {version_path}"
        ) from error


def verify_contract(
    *,
    project_root: Path = PROJECT_ROOT,
    contract_path: Path = DEFAULT_CONTRACT,
    rebase_plan_path: Path = DEFAULT_REBASE_PLAN,
) -> dict[str, Any]:
    project_root = project_root.resolve()
    contract_path = contract_path.resolve()
    rebase_plan_path = rebase_plan_path.resolve()
    contract = load_object(contract_path, "Chromium source contract")
    plan = load_object(rebase_plan_path, "Chromium rebase plan")
    ensure_no_stale_markers(contract, "Chromium source contract")

    if contract.get("schemaVersion") != 1:
        raise SourceProvenanceError("Unexpected Chromium source contract schema")
    if plan.get("schemaVersion") != 1:
        raise SourceProvenanceError("Unexpected Chromium rebase plan schema")
    if contract.get("binaryBindingStatus") != "pending-new-build":
        raise SourceProvenanceError(
            "Source contract must remain binaryBindingStatus=pending-new-build "
            "until a new runtime build records its provenance SHA-256"
        )
    if contract.get("sourceMode") != "owned-rebase":
        raise SourceProvenanceError("Source contract must use owned-rebase")
    if contract.get("targetArchitecture") != "arm64":
        raise SourceProvenanceError("Source contract must target arm64")

    actual_plan_sha = sha256_file(rebase_plan_path)
    if require_sha256(
        contract.get("rebasePlanSHA256"),
        "rebasePlanSHA256",
    ) != actual_plan_sha:
        raise SourceProvenanceError("Source contract rebase-plan SHA-256 is stale")

    target = require_text(
        contract.get("targetChromiumVersion"),
        "targetChromiumVersion",
    )
    if target != plan.get("targetChromiumVersion"):
        raise SourceProvenanceError(
            "Source contract target does not match Chromium rebase plan"
        )

    mac = contract.get("macPackaging")
    common = contract.get("commonChromium")
    official = contract.get("officialChromiumBase")
    if not all(isinstance(value, dict) for value in (mac, common, official)):
        raise SourceProvenanceError(
            "Source contract must contain officialChromiumBase, macPackaging, "
            "and commonChromium objects"
        )
    assert isinstance(mac, dict)
    assert isinstance(common, dict)
    assert isinstance(official, dict)
    if "tag" in mac:
        raise SourceProvenanceError(
            "macPackaging is commit-pinned and must not invent an exact tag"
        )

    plan_mac = plan.get("macPackaging")
    plan_common = plan.get("commonChromium")
    if not isinstance(plan_mac, dict) or not isinstance(plan_common, dict):
        raise SourceProvenanceError(
            "Chromium rebase plan is missing source-pair objects"
        )
    exact_pairs = (
        (
            require_text(mac.get("repository"), "macPackaging.repository"),
            plan_mac.get("repository"),
            "macPackaging.repository",
        ),
        (
            require_git_object(mac.get("commit"), "macPackaging.commit"),
            plan_mac.get("commit"),
            "macPackaging.commit",
        ),
        (
            require_text(
                mac.get("packagedChromiumVersion"),
                "macPackaging.packagedChromiumVersion",
            ),
            plan_mac.get("packagedChromiumVersion"),
            "macPackaging.packagedChromiumVersion",
        ),
        (
            require_text(common.get("repository"), "commonChromium.repository"),
            plan_common.get("repository"),
            "commonChromium.repository",
        ),
        (
            require_text(common.get("tag"), "commonChromium.tag"),
            plan_common.get("tag"),
            "commonChromium.tag",
        ),
        (
            require_git_object(common.get("commit"), "commonChromium.commit"),
            plan_common.get("commit"),
            "commonChromium.commit",
        ),
    )
    for actual, expected, label in exact_pairs:
        if actual != expected:
            raise SourceProvenanceError(
                f"Source contract {label} does not match rebase plan"
            )

    for owner_name, owner in (
        ("officialChromiumBase", official),
        ("macPackaging", mac),
        ("commonChromium", common),
    ):
        require_text(owner.get("repository"), f"{owner_name}.repository")
        require_git_object(owner.get("commit"), f"{owner_name}.commit")
        require_git_object(owner.get("tree"), f"{owner_name}.tree")
    if require_text(
        official.get("tag"),
        "officialChromiumBase.tag",
    ) != target:
        raise SourceProvenanceError(
            "officialChromiumBase.tag must equal targetChromiumVersion"
        )
    official_license_sha = require_sha256(
        official.get("licenseSHA256"),
        "officialChromiumBase.licenseSHA256",
    )
    chromium_license = project_root / "runtime" / "licenses" / "Chromium-LICENSE"
    if (
        not chromium_license.is_file()
        or chromium_license.is_symlink()
        or sha256_file(chromium_license) != official_license_sha
    ):
        raise SourceProvenanceError(
            "Packaged Chromium license does not match source contract"
        )
    require_git_object(
        mac.get("recordedCommonSubmoduleCommit"),
        "macPackaging.recordedCommonSubmoduleCommit",
    )
    require_git_object(
        common.get("tagObject"),
        "commonChromium.tagObject",
    )
    archive = official.get("liteArchive")
    if not isinstance(archive, dict):
        raise SourceProvenanceError(
            "officialChromiumBase.liteArchive must be an object"
        )
    require_text(
        archive.get("filename"),
        "officialChromiumBase.liteArchive.filename",
    )
    require_sha256(
        archive.get("sha256"),
        "officialChromiumBase.liteArchive.sha256",
    )
    require_sha256(
        archive.get("hashesFileSHA256"),
        "officialChromiumBase.liteArchive.hashesFileSHA256",
    )

    critical_owners = (("macPackaging", mac), ("commonChromium", common))
    for owner_name, owner in critical_owners:
        critical = owner.get("criticalFiles")
        if not isinstance(critical, dict) or not critical:
            raise SourceProvenanceError(
                f"{owner_name}.criticalFiles must be a non-empty object"
            )
        for relative, digest in critical.items():
            if not isinstance(relative, str) or not relative or relative.startswith("/"):
                raise SourceProvenanceError(
                    f"{owner_name}.criticalFiles contains an unsafe path"
                )
            require_sha256(digest, f"{owner_name}.criticalFiles.{relative}")

    contract_override = contract.get("sourceVersionOverride")
    plan_override = plan.get("sourceVersionOverride")
    if (
        not isinstance(contract_override, dict)
        or not isinstance(plan_override, dict)
    ):
        raise SourceProvenanceError(
            "Source contract and rebase plan must contain sourceVersionOverride"
        )
    override_from = require_text(
        contract_override.get("from"),
        "sourceVersionOverride.from",
    )
    override_to = require_text(
        contract_override.get("to"),
        "sourceVersionOverride.to",
    )
    if (
        override_from != plan_override.get("from")
        or override_to != plan_override.get("to")
    ):
        raise SourceProvenanceError(
            "Source contract sourceVersionOverride does not match rebase plan"
        )
    if override_to != target:
        raise SourceProvenanceError(
            "sourceVersionOverride.to must equal targetChromiumVersion"
        )
    common_critical = common["criticalFiles"]
    assert isinstance(common_critical, dict)
    original_version_sha = sha256_bytes(f"{override_from}\n".encode("utf-8"))
    if common_critical.get("chromium_version.txt") != original_version_sha:
        raise SourceProvenanceError(
            "sourceVersionOverride.from does not match the locked common "
            "chromium_version.txt preimage"
        )
    modified_version_sha = require_sha256(
        contract_override.get("modifiedCriticalFileSHA256"),
        "sourceVersionOverride.modifiedCriticalFileSHA256",
    )
    expected_modified_sha = sha256_bytes(f"{override_to}\n".encode("utf-8"))
    if modified_version_sha != expected_modified_sha:
        raise SourceProvenanceError(
            "sourceVersionOverride modified critical-file SHA-256 is stale"
        )

    owned = contract.get("ownedInputs")
    if not isinstance(owned, dict) or not owned:
        raise SourceProvenanceError("ownedInputs must be a non-empty object")
    for relative, expected in owned.items():
        if (
            not isinstance(relative, str)
            or not relative
            or relative.startswith("/")
            or ".." in Path(relative).parts
        ):
            raise SourceProvenanceError(f"Unsafe owned input path: {relative!r}")
        expected_sha = require_sha256(expected, f"ownedInputs.{relative}")
        path = project_root / relative
        if not path.is_file() or path.is_symlink():
            raise SourceProvenanceError(
                f"Owned provenance input is missing or symlinked: {relative}"
            )
        actual_sha = sha256_file(path)
        if actual_sha != expected_sha:
            raise SourceProvenanceError(
                f"Owned provenance input hash mismatch: {relative}"
            )

    return contract


def verify_repository(
    repository: Path,
    expected: dict[str, Any],
    *,
    label: str,
) -> dict[str, Any]:
    if not repository.is_dir() or not (repository / ".git").exists():
        raise SourceProvenanceError(f"{label} checkout is missing: {repository}")
    head = git_output(repository, "rev-parse", "HEAD")
    tree = git_output(repository, "rev-parse", "HEAD^{tree}")
    if head != expected["commit"]:
        raise SourceProvenanceError(
            f"{label} HEAD mismatch: expected {expected['commit']}, got {head}"
        )
    if tree != expected["tree"]:
        raise SourceProvenanceError(
            f"{label} tree mismatch: expected {expected['tree']}, got {tree}"
        )
    critical = expected["criticalFiles"]
    verified_files: dict[str, str] = {}
    for relative, expected_sha in critical.items():
        actual_sha = git_object_sha256(repository, f"HEAD:{relative}")
        if actual_sha != expected_sha:
            raise SourceProvenanceError(
                f"{label} locked Git file hash mismatch: {relative}"
            )
        verified_files[relative] = actual_sha
    return {
        "repository": expected["repository"],
        "commit": head,
        "tree": tree,
        "criticalFiles": verified_files,
    }


def default_check_runner(command: list[str], label: str) -> str:
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise SourceProvenanceError(
            f"{label} failed:\n{completed.stdout.strip()}"
        )
    return completed.stdout.strip()


def build_provenance(
    source_root: Path,
    *,
    project_root: Path = PROJECT_ROOT,
    contract_path: Path = DEFAULT_CONTRACT,
    rebase_plan_path: Path = DEFAULT_REBASE_PLAN,
    check_runner: Callable[[list[str], str], str] = default_check_runner,
) -> dict[str, Any]:
    if not source_root.is_absolute():
        raise SourceProvenanceError("Chromium source root must be absolute")
    source_root = source_root.resolve()
    if not source_root.is_dir():
        raise SourceProvenanceError(
            f"Chromium source root does not exist: {source_root}"
        )
    build_dir = source_root.parent
    if source_root.name != "src" or build_dir.name != "build":
        raise SourceProvenanceError(
            "Chromium source root must use the pinned <build-root>/build/src layout"
        )
    build_root = build_dir.parent
    common_root = build_root / "ungoogled-chromium"

    project_root = project_root.resolve()
    contract_path = contract_path.resolve()
    rebase_plan_path = rebase_plan_path.resolve()
    contract = verify_contract(
        project_root=project_root,
        contract_path=contract_path,
        rebase_plan_path=rebase_plan_path,
    )
    mac_expected = contract["macPackaging"]
    common_expected = contract["commonChromium"]
    assert isinstance(mac_expected, dict)
    assert isinstance(common_expected, dict)
    mac = verify_repository(build_root, mac_expected, label="macPackaging")
    common = verify_repository(
        common_root,
        common_expected,
        label="commonChromium",
    )

    recorded_submodule = git_output(
        build_root,
        "rev-parse",
        "HEAD:ungoogled-chromium",
    )
    if recorded_submodule != mac_expected["recordedCommonSubmoduleCommit"]:
        raise SourceProvenanceError(
            "macPackaging recorded common submodule commit is not locked"
        )
    common["tag"] = common_expected["tag"]
    tag_ref = f"refs/tags/{common_expected['tag']}"
    tag_object = git_output(common_root, "rev-parse", tag_ref)
    peeled = git_output(common_root, "rev-parse", f"{tag_ref}^{{}}")
    if tag_object != common_expected["tagObject"] or peeled != common["commit"]:
        raise SourceProvenanceError(
            "commonChromium tag object or peeled commit does not match contract"
        )
    common["tagObject"] = tag_object
    mac["packagedChromiumVersion"] = mac_expected["packagedChromiumVersion"]
    mac["recordedCommonSubmoduleCommit"] = recorded_submodule
    mac["effectiveCommonCommit"] = common["commit"]

    version = chromium_version(source_root)
    if version != contract["targetChromiumVersion"]:
        raise SourceProvenanceError(
            f"Chromium source version mismatch: expected "
            f"{contract['targetChromiumVersion']}, got {version}"
        )

    official = contract["officialChromiumBase"]
    assert isinstance(official, dict)
    archive = official.get("liteArchive")
    if not isinstance(archive, dict):
        raise SourceProvenanceError(
            "officialChromiumBase.liteArchive must be an object"
        )
    cache = build_dir / "download_cache"
    archive_path = cache / require_text(
        archive.get("filename"),
        "officialChromiumBase.liteArchive.filename",
    )
    hashes_path = cache / f"{archive_path.name}.hashes"
    for path, expected_sha, label in (
        (
            archive_path,
            require_sha256(
                archive.get("sha256"),
                "officialChromiumBase.liteArchive.sha256",
            ),
            "official Chromium source archive",
        ),
        (
            hashes_path,
            require_sha256(
                archive.get("hashesFileSHA256"),
                "officialChromiumBase.liteArchive.hashesFileSHA256",
            ),
            "official Chromium source hashes file",
        ),
    ):
        if not path.is_file() or path.is_symlink():
            raise SourceProvenanceError(f"{label} is missing or symlinked")
        if sha256_file(path) != expected_sha:
            raise SourceProvenanceError(f"{label} SHA-256 mismatch")

    patch_output = check_runner(
        [
            sys.executable,
            os.fspath(project_root / "scripts" / "apply-neantik-patchset.py"),
            os.fspath(source_root),
            "--check",
            "--rebase-plan",
            os.fspath(rebase_plan_path),
        ],
        "Owned NeAntik patchset check",
    )
    try:
        patch_result = json.loads(patch_output)
    except json.JSONDecodeError as error:
        raise SourceProvenanceError(
            "Owned NeAntik patchset check did not return JSON"
        ) from error
    if patch_result.get("status") != "already-applied":
        raise SourceProvenanceError(
            "Owned NeAntik patchset must be fully applied before provenance export"
        )
    tuple_output = check_runner(
        [
            sys.executable,
            os.fspath(
                project_root
                / "scripts"
                / "apply-owned-runtime-device-tuples.py"
            ),
            os.fspath(source_root),
            "--check",
        ],
        "Owned Apple device tuple check",
    )
    if "verified" not in tuple_output.lower():
        raise SourceProvenanceError(
            "Owned Apple device tuple check returned no verification result"
        )

    owned = contract["ownedInputs"]
    assert isinstance(owned, dict)
    document = {
        "schemaVersion": 1,
        "binaryBindingStatus": "pending-new-build",
        "contractSHA256": sha256_file(contract_path),
        "rebasePlanSHA256": sha256_file(rebase_plan_path),
        "targetChromiumVersion": version,
        "targetArchitecture": "arm64",
        "sourceMode": "owned-rebase",
        "officialChromiumBase": official,
        "macPackaging": mac,
        "commonChromium": common,
        "ownedInputs": owned,
        "sourceChecks": {
            "chromiumVersion": "verified",
            "officialArchiveSHA256": "verified",
            "macGitObjects": "verified",
            "commonGitObjects": "verified",
            "ownedPatchset": "already-applied",
            "ownedAppleDeviceTuples": "verified",
        },
    }
    ensure_no_stale_markers(document, "emitted source provenance")
    return document


def expected_static_document(
    *,
    project_root: Path = PROJECT_ROOT,
    contract_path: Path = DEFAULT_CONTRACT,
    rebase_plan_path: Path = DEFAULT_REBASE_PLAN,
) -> dict[str, Any]:
    contract = verify_contract(
        project_root=project_root,
        contract_path=contract_path,
        rebase_plan_path=rebase_plan_path,
    )
    mac = dict(contract["macPackaging"])
    common = dict(contract["commonChromium"])
    mac["effectiveCommonCommit"] = common["commit"]
    return {
        "schemaVersion": 1,
        "binaryBindingStatus": "pending-new-build",
        "contractSHA256": sha256_file(contract_path),
        "rebasePlanSHA256": sha256_file(rebase_plan_path),
        "targetChromiumVersion": contract["targetChromiumVersion"],
        "targetArchitecture": "arm64",
        "sourceMode": "owned-rebase",
        "officialChromiumBase": contract["officialChromiumBase"],
        "macPackaging": mac,
        "commonChromium": common,
        "ownedInputs": contract["ownedInputs"],
    }


def verify_document(
    document: dict[str, Any],
    *,
    project_root: Path = PROJECT_ROOT,
    contract_path: Path = DEFAULT_CONTRACT,
    rebase_plan_path: Path = DEFAULT_REBASE_PLAN,
) -> None:
    ensure_no_stale_markers(document, "emitted source provenance")
    expected = expected_static_document(
        project_root=project_root,
        contract_path=contract_path,
        rebase_plan_path=rebase_plan_path,
    )
    expected_keys = {*expected, "sourceChecks"}
    if set(document) != expected_keys:
        raise SourceProvenanceError(
            "Emitted provenance has missing or unexpected top-level fields"
        )
    for key, expected_value in expected.items():
        actual = document.get(key)
        if actual != expected_value:
            if key in {"macPackaging", "commonChromium"} and isinstance(
                actual, dict
            ) and isinstance(expected_value, dict):
                field = next(
                    (
                        candidate
                        for candidate in sorted({*actual, *expected_value})
                        if actual.get(candidate) != expected_value.get(candidate)
                    ),
                    "<unknown>",
                )
                raise SourceProvenanceError(
                    f"Emitted provenance mismatch: {key}.{field}"
                )
            raise SourceProvenanceError(f"Emitted provenance mismatch: {key}")
    checks = document.get("sourceChecks")
    expected_checks = {
        "chromiumVersion": "verified",
        "officialArchiveSHA256": "verified",
        "macGitObjects": "verified",
        "commonGitObjects": "verified",
        "ownedPatchset": "already-applied",
        "ownedAppleDeviceTuples": "verified",
    }
    if checks != expected_checks:
        raise SourceProvenanceError("Emitted provenance sourceChecks are incomplete")


def verify_runtime_lock_for_new_candidate(
    runtime_lock_path: Path,
    *,
    project_root: Path = PROJECT_ROOT,
    contract_path: Path = DEFAULT_CONTRACT,
    rebase_plan_path: Path = DEFAULT_REBASE_PLAN,
) -> None:
    lock = load_object(runtime_lock_path, "new-candidate runtime lock")
    ensure_no_stale_markers(lock, "new-candidate runtime lock")
    if lock.get("schemaVersion") != 4:
        raise SourceProvenanceError(
            "New-candidate runtime lock must use source-contract schema 4"
        )
    contract = verify_contract(
        project_root=project_root,
        contract_path=contract_path,
        rebase_plan_path=rebase_plan_path,
    )
    expected_contract_sha = sha256_file(contract_path)
    if lock.get("sourceContractSHA256") != expected_contract_sha:
        raise SourceProvenanceError(
            "New-candidate runtime lock is not bound to the Chromium "
            "source contract"
        )
    fingerprint = lock.get("fingerprintChromium")
    mac = lock.get("macPackaging")
    common = lock.get("commonChromium")
    if not all(isinstance(value, dict) for value in (fingerprint, mac, common)):
        raise SourceProvenanceError(
            "New-candidate runtime lock must declare fingerprintChromium, "
            "macPackaging, and effective commonChromium"
        )
    assert isinstance(fingerprint, dict)
    assert isinstance(mac, dict)
    assert isinstance(common, dict)
    if fingerprint.get("chromiumVersion") != contract["targetChromiumVersion"]:
        raise SourceProvenanceError(
            "New-candidate runtime lock Chromium version differs from source contract"
        )
    legacy_fingerprint_fields = {
        "patchSeriesSHA256",
        "fingerprintPatchTree",
        "flagsSHA256",
        "downloadsSHA256",
        "pruningSHA256",
    }
    retained_legacy = sorted(legacy_fingerprint_fields.intersection(fingerprint))
    if retained_legacy:
        raise SourceProvenanceError(
            "New-candidate runtime lock retains legacy fingerprintChromium "
            "integration fields: " + ", ".join(retained_legacy)
        )
    official = contract["officialChromiumBase"]
    for label, actual, expected in (
        (
            "fingerprintChromium.repository",
            fingerprint.get("repository"),
            official["repository"],
        ),
        (
            "fingerprintChromium.tag",
            fingerprint.get("tag"),
            official["tag"],
        ),
        (
            "fingerprintChromium.commit",
            fingerprint.get("commit"),
            official["commit"],
        ),
        (
            "fingerprintChromium.tree",
            fingerprint.get("tree"),
            official["tree"],
        ),
        (
            "macPackaging.criticalFiles",
            mac.get("criticalFiles"),
            contract["macPackaging"]["criticalFiles"],
        ),
        (
            "commonChromium.criticalFiles",
            common.get("criticalFiles"),
            contract["commonChromium"]["criticalFiles"],
        ),
    ):
        if actual != expected:
            raise SourceProvenanceError(
                f"New-candidate runtime lock mismatch: {label}"
            )
    for label, actual, expected in (
        ("macPackaging.commit", mac.get("commit"), contract["macPackaging"]["commit"]),
        ("macPackaging.tree", mac.get("tree"), contract["macPackaging"]["tree"]),
        (
            "commonChromium.commit",
            common.get("commit"),
            contract["commonChromium"]["commit"],
        ),
        (
            "commonChromium.tree",
            common.get("tree"),
            contract["commonChromium"]["tree"],
        ),
        (
            "commonChromium.tag",
            common.get("tag"),
            contract["commonChromium"]["tag"],
        ),
    ):
        if actual != expected:
            raise SourceProvenanceError(
                f"New-candidate runtime lock mismatch: {label}"
            )
    if "tag" in mac:
        raise SourceProvenanceError(
            "New-candidate macPackaging lock must remain commit-pinned without "
            "an invented tag"
        )


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    if not path.is_absolute():
        raise SourceProvenanceError("Source provenance output must be absolute")
    if path.is_symlink():
        raise SourceProvenanceError(
            "Refusing to replace symlinked source provenance output"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    ).encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(payload)
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)
