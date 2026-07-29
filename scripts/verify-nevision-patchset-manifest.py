#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = PROJECT_ROOT / "runtime" / "nevision-patches" / "series.json"
DEFAULT_REBASE_PLAN = PROJECT_ROOT / "runtime" / "chromium-150-rebase-plan.json"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
ALLOWED_STATUSES = {"planned", "ported"}
ALLOWED_MANIFEST_STATUSES = {
    "planned-not-ported",
    "partially-ported",
    "release-ready",
}


class PatchsetManifestError(ValueError):
    pass


def load_object(path: Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PatchsetManifestError(f"Cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise PatchsetManifestError(f"{label} must be a JSON object")
    return value


def require_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PatchsetManifestError(f"{field} must be a non-empty string")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def assert_safe_relative_path(value: str, *, field: str) -> Path:
    path = Path(value)
    if (
        not value
        or path.is_absolute()
        or ".." in path.parts
        or any(part in ("", ".") for part in path.parts)
    ):
        raise PatchsetManifestError(f"{field} must be a safe relative path: {value}")
    return path


def assert_patch_scope_allowed(patch_path: Path, forbidden_scopes: list[str], group_id: str) -> None:
    try:
        patch_text = patch_path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        raise PatchsetManifestError(f"{group_id} patchFile cannot be read: {error}") from error
    lowered = patch_text.lower()
    for scope in forbidden_scopes:
        if scope.lower() in lowered:
            raise PatchsetManifestError(
                f"{group_id} patchFile contains forbidden scope marker: {scope}"
            )


def apply_check(source_root: Path, patch_path: Path) -> None:
    repository = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "--show-toplevel"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    apply_root = source_root
    directory_options: list[str] = []
    if repository.returncode == 0:
        apply_root = Path(repository.stdout.strip()).resolve()
        try:
            relative_root = source_root.resolve().relative_to(apply_root)
        except ValueError as error:
            raise PatchsetManifestError(
                f"source root escapes detected Git worktree: {source_root}"
            ) from error
        if relative_root != Path("."):
            directory_options = [f"--directory={relative_root.as_posix()}"]
    completed = subprocess.run(
        [
            "git",
            "-C",
            str(apply_root),
            "apply",
            "--check",
            "--whitespace=nowarn",
            *directory_options,
            str(patch_path),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0 or "Skipped patch" in completed.stdout:
        raise PatchsetManifestError(
            f"patch does not apply cleanly with git apply --check: {patch_path.name}\n"
            + completed.stdout.strip()
        )


def verify_source_evidence_paths(
    *,
    project_root: Path,
    group_id: str,
    evidence: list[str],
) -> None:
    for relative in evidence:
        evidence_path = assert_safe_relative_path(
            relative,
            field=f"{group_id}.sourceEvidence",
        )
        if not (project_root / evidence_path).is_file():
            raise PatchsetManifestError(
                f"{group_id}.sourceEvidence is missing: {relative}"
            )


def verify_generated_inputs(
    *,
    project_root: Path,
    generated_inputs: object,
) -> list[dict[str, object]]:
    if not isinstance(generated_inputs, list) or not generated_inputs:
        raise PatchsetManifestError(
            "generatedInputs must be a non-empty list"
        )
    diagnostics: list[dict[str, object]] = []
    seen_ids: set[str] = set()
    for index, value in enumerate(generated_inputs):
        if not isinstance(value, dict):
            raise PatchsetManifestError(
                f"generatedInputs[{index}] must be an object"
            )
        input_id = require_string(
            value.get("id"),
            f"generatedInputs[{index}].id",
        )
        if input_id in seen_ids:
            raise PatchsetManifestError(
                f"duplicate generated input id: {input_id}"
            )
        seen_ids.add(input_id)
        resolved: dict[str, Path] = {}
        for path_field, hash_field in (
            ("catalogPath", "catalogSHA256"),
            ("generatorPath", "generatorSHA256"),
        ):
            relative_value = require_string(
                value.get(path_field),
                f"{input_id}.{path_field}",
            )
            relative = assert_safe_relative_path(
                relative_value,
                field=f"{input_id}.{path_field}",
            )
            path = project_root / relative
            if not path.is_file():
                raise PatchsetManifestError(
                    f"{input_id}.{path_field} is missing: {relative_value}"
                )
            expected = value.get(hash_field)
            if not isinstance(expected, str) or not re.fullmatch(
                r"[0-9a-f]{64}",
                expected,
            ):
                raise PatchsetManifestError(
                    f"{input_id}.{hash_field} must be a SHA-256 string"
                )
            actual = sha256(path)
            if actual != expected:
                raise PatchsetManifestError(
                    f"{input_id}.{hash_field} mismatch: {actual} != {expected}"
                )
            resolved[path_field] = path
        postimages = value.get("postimageSHA256")
        if not isinstance(postimages, dict) or not postimages:
            raise PatchsetManifestError(
                f"{input_id}.postimageSHA256 must be a non-empty object"
            )
        for relative, digest in postimages.items():
            if not isinstance(relative, str):
                raise PatchsetManifestError(
                    f"{input_id}.postimageSHA256 paths must be strings"
                )
            assert_safe_relative_path(
                relative,
                field=f"{input_id}.postimageSHA256",
            )
            if not isinstance(digest, str) or not re.fullmatch(
                r"[0-9a-f]{64}",
                digest,
            ):
                raise PatchsetManifestError(
                    f"{input_id}.postimageSHA256 must map paths to SHA-256 strings"
                )
        diagnostics.append(
            {
                "id": input_id,
                "catalogPath": str(
                    resolved["catalogPath"].relative_to(project_root)
                ),
                "generatorPath": str(
                    resolved["generatorPath"].relative_to(project_root)
                ),
                "postimageCount": len(postimages),
            }
        )
    return diagnostics


def verify_manifest(
    *,
    manifest_path: Path,
    rebase_plan_path: Path,
    release: bool,
    source_root: Path | None = None,
    verify_source_evidence: bool = False,
    project_root: Path = PROJECT_ROOT,
) -> dict[str, object]:
    manifest = load_object(manifest_path, "NeAntik patchset manifest")
    rebase_plan = load_object(rebase_plan_path, "Chromium 150 rebase plan")
    if manifest.get("schemaVersion") != 1:
        raise PatchsetManifestError("Unexpected patchset manifest schema")
    manifest_status = require_string(manifest.get("status"), "status")
    if manifest_status not in ALLOWED_MANIFEST_STATUSES:
        raise PatchsetManifestError(
            "status must be one of: " + ", ".join(sorted(ALLOWED_MANIFEST_STATUSES))
        )
    require_string(manifest.get("policy"), "policy")
    target = require_string(manifest.get("targetChromiumVersion"), "targetChromiumVersion")
    if not VERSION_RE.fullmatch(target):
        raise PatchsetManifestError("targetChromiumVersion must be a four-part version")
    if target != rebase_plan.get("targetChromiumVersion"):
        raise PatchsetManifestError(
            "patchset targetChromiumVersion must match chromium-150-rebase-plan.json"
        )
    forbidden_scope_values = manifest.get("forbiddenScopes")
    if not isinstance(forbidden_scope_values, list) or not forbidden_scope_values:
        raise PatchsetManifestError("forbiddenScopes must be a non-empty list")
    if not all(
        isinstance(item, str)
        and re.fullmatch(r"[a-z][a-z0-9-]*", item)
        for item in forbidden_scope_values
    ):
        raise PatchsetManifestError("forbiddenScopes must contain safe scope strings")
    if len(set(forbidden_scope_values)) != len(forbidden_scope_values):
        raise PatchsetManifestError("forbiddenScopes must be unique")
    forbidden_scopes = [str(item) for item in forbidden_scope_values]
    generated_input_diagnostics = verify_generated_inputs(
        project_root=manifest_path.resolve().parents[2],
        generated_inputs=manifest.get("generatedInputs"),
    )

    groups = manifest.get("patchGroups")
    if not isinstance(groups, list) or not groups:
        raise PatchsetManifestError("patchGroups must be a non-empty list")

    ids: set[str] = set()
    missing_for_release: list[str] = []
    planned_for_release: list[str] = []
    group_diagnostics: list[dict[str, object]] = []
    for index, group in enumerate(groups):
        if not isinstance(group, dict):
            raise PatchsetManifestError(f"patchGroups[{index}] must be an object")
        group_id = require_string(group.get("id"), f"patchGroups[{index}].id")
        if group_id in ids:
            raise PatchsetManifestError(f"duplicate patch group id: {group_id}")
        ids.add(group_id)
        status = group.get("status")
        if status not in ALLOWED_STATUSES:
            raise PatchsetManifestError(f"{group_id} has invalid status: {status!r}")
        if group.get("releaseRequired") is not True:
            raise PatchsetManifestError(f"{group_id} must be releaseRequired=true")
        for field in ("sourceEvidence", "requiredBehavior"):
            value = group.get(field)
            if not isinstance(value, list) or not value or not all(
                isinstance(item, str) and item for item in value
            ):
                raise PatchsetManifestError(f"{group_id}.{field} must be a non-empty string list")
        source_evidence = [str(item) for item in group["sourceEvidence"]]
        if verify_source_evidence:
            verify_source_evidence_paths(
                project_root=project_root,
                group_id=group_id,
                evidence=source_evidence,
            )
        patch_file = group.get("patchFile")
        patch_digest = group.get("patchSHA256")
        postimages = group.get("postimageSHA256")
        if not isinstance(postimages, dict):
            raise PatchsetManifestError(f"{group_id}.postimageSHA256 must be an object")
        if status == "ported":
            if not isinstance(patch_file, str) or not patch_file:
                raise PatchsetManifestError(f"{group_id} is ported but has no patchFile")
            patch_relative = assert_safe_relative_path(
                patch_file,
                field=f"{group_id}.patchFile",
            )
            patch_path = manifest_path.parent / patch_relative
            if not patch_path.is_file():
                raise PatchsetManifestError(f"{group_id} patchFile is missing: {patch_file}")
            if not isinstance(patch_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", patch_digest):
                raise PatchsetManifestError(f"{group_id} is ported but has no valid patchSHA256")
            assert_patch_scope_allowed(patch_path, forbidden_scopes, group_id)
            actual_digest = sha256(patch_path)
            if actual_digest != patch_digest:
                raise PatchsetManifestError(
                    f"{group_id} patchSHA256 mismatch: {actual_digest} != {patch_digest}"
                )
            if not postimages:
                raise PatchsetManifestError(f"{group_id} is ported but has no postimage hashes")
            for relative, digest in postimages.items():
                if not isinstance(relative, str):
                    raise PatchsetManifestError(
                        f"{group_id}.postimageSHA256 source paths must be strings"
                    )
                assert_safe_relative_path(
                    relative,
                    field=f"{group_id}.postimageSHA256",
                )
                if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                    raise PatchsetManifestError(
                        f"{group_id}.postimageSHA256 must map source paths to SHA-256 strings"
                    )
            if source_root is not None:
                apply_check(source_root, patch_path)
            group_diagnostics.append(
                {
                    "id": group_id,
                    "status": "ported",
                    "patchFile": patch_file,
                    "postimageCount": len(postimages),
                    "sourceEvidenceCount": len(source_evidence),
                    "requiredBehaviorCount": len(group["requiredBehavior"]),
                }
            )
        else:
            if patch_file is not None:
                raise PatchsetManifestError(f"{group_id} is planned but has patchFile")
            if patch_digest is not None:
                raise PatchsetManifestError(f"{group_id} is planned but has patchSHA256")
            if postimages:
                raise PatchsetManifestError(f"{group_id} is planned but has postimage hashes")
            planned_for_release.append(group_id)
            if release:
                missing_for_release.append(group_id)
            group_diagnostics.append(
                {
                    "id": group_id,
                    "status": "planned",
                    "patchFile": None,
                    "postimageCount": 0,
                    "sourceEvidenceCount": len(source_evidence),
                    "requiredBehaviorCount": len(group["requiredBehavior"]),
                }
            )

    ported_count = sum(
        1
        for group in groups
        if isinstance(group, dict) and group.get("status") == "ported"
    )
    planned_count = sum(
        1
        for group in groups
        if isinstance(group, dict) and group.get("status") == "planned"
    )
    expected_manifest_status = (
        "release-ready"
        if planned_count == 0
        else "planned-not-ported"
        if ported_count == 0
        else "partially-ported"
    )
    if manifest_status != expected_manifest_status:
        raise PatchsetManifestError(
            f"status must be {expected_manifest_status} for "
            f"{planned_count} planned and {ported_count} ported group(s)"
        )

    summary = {
        "manifestStatus": manifest_status,
        "targetChromiumVersion": target,
        "groupCount": len(groups),
        "portedCount": ported_count,
        "plannedCount": planned_count,
        "generatedInputCount": len(generated_input_diagnostics),
        "generatedInputs": generated_input_diagnostics,
        "releaseReady": not planned_for_release,
        "missingForRelease": planned_for_release,
        "groups": group_diagnostics,
    }
    if release and missing_for_release:
        raise PatchsetManifestError(
            "NeAntik Chromium patchset is not release-ready: "
            + ", ".join(missing_for_release)
        )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the owned NeAntik Chromium patchset manifest.",
    )
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--rebase-plan", type=Path, default=DEFAULT_REBASE_PLAN)
    parser.add_argument("--release", action="store_true")
    parser.add_argument(
        "--source-root",
        type=Path,
        help="Chromium source root for git apply --check of ported patch files.",
    )
    parser.add_argument(
        "--source-evidence",
        action="store_true",
        help="Verify every sourceEvidence path exists in the NeAntik project.",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        summary = verify_manifest(
            manifest_path=args.manifest,
            rebase_plan_path=args.rebase_plan,
            release=args.release,
            source_root=args.source_root,
            verify_source_evidence=args.source_evidence,
            project_root=PROJECT_ROOT,
        )
    except PatchsetManifestError as error:
        raise SystemExit(str(error)) from error
    if args.json:
        print(json.dumps(summary, indent=2))
    elif summary["releaseReady"]:
        print(
            "NeAntik Chromium patchset manifest verified: "
            f"{summary['groupCount']} release-required group(s) are ported."
        )
    else:
        print(
            "NeAntik Chromium patchset manifest verified as a port plan: "
            f"{summary['plannedCount']} planned group(s), "
            f"{summary['portedCount']} ported group(s)."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
