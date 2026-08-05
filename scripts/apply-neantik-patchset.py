#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = PROJECT_ROOT / "runtime" / "nevision-patches" / "series.json"
REBASE_PLAN_PATH = PROJECT_ROOT / "runtime" / "chromium-151-rebase-plan.json"
VERIFIER_PATH = PROJECT_ROOT / "scripts" / "verify-nevision-patchset-manifest.py"

SPEC = importlib.util.spec_from_file_location(
    "verify_neantik_patchset_manifest",
    VERIFIER_PATH,
)
assert SPEC and SPEC.loader
VERIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFIER
SPEC.loader.exec_module(VERIFIER)


class PatchApplicationError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def chromium_version(source_root: Path) -> str:
    version_path = source_root / "chrome" / "VERSION"
    try:
        pairs = dict(
            line.split("=", 1)
            for line in version_path.read_text(encoding="utf-8").splitlines()
            if "=" in line
        )
        return ".".join(pairs[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH"))
    except (OSError, KeyError, ValueError) as error:
        raise PatchApplicationError(
            f"Cannot read complete Chromium version from {version_path}"
        ) from error


def git_apply_command(
    source_root: Path,
    patch_paths: list[Path],
    *options: str,
) -> tuple[list[str], Path]:
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
            relative_root = source_root.relative_to(apply_root)
        except ValueError as error:
            raise PatchApplicationError(
                f"Chromium source root escapes detected Git worktree: {source_root}"
            ) from error
        if relative_root != Path("."):
            directory_options = [f"--directory={relative_root.as_posix()}"]
    return (
        [
            "git",
            "-C",
            str(apply_root),
            "apply",
            *options,
            "--whitespace=nowarn",
            *directory_options,
            *(str(path) for path in patch_paths),
        ],
        apply_root,
    )


def run_git_apply(source_root: Path, patch_paths: list[Path], *options: str) -> None:
    command, apply_root = git_apply_command(source_root, patch_paths, *options)
    completed = subprocess.run(
        command,
        cwd=apply_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0 or "Skipped patch" in completed.stdout:
        detail = completed.stdout.strip()
        raise PatchApplicationError(
            "Owned NeAntik patch series does not apply atomically"
            + (f":\n{detail}" if detail else ".")
        )


def postimage_state(
    source_root: Path,
    groups: list[dict[str, object]],
    generated_postimages: dict[str, str],
) -> tuple[int, int, list[str]]:
    final_patch_postimages: dict[str, str] = {}
    for group in groups:
        final_patch_postimages.update(
            {
                str(relative): str(digest)
                for relative, digest in group["postimageSHA256"].items()
            }
        )
    matched = 0
    total = 0
    mismatches: list[str] = []
    for group in groups:
        postimages = group["postimageSHA256"]
        assert isinstance(postimages, dict)
        for relative, expected in postimages.items():
            total += 1
            path = source_root / str(relative)
            actual = sha256(path) if path.is_file() else "missing"
            accepted = {
                str(expected),
                final_patch_postimages[str(relative)],
                *(
                    [generated_postimages[str(relative)]]
                    if str(relative) in generated_postimages
                    else []
                ),
            }
            if actual in accepted:
                matched += 1
            else:
                mismatches.append(
                    f"{group['id']}:{relative}: expected one of "
                    f"{sorted(accepted)}, actual {actual}"
                )
    return matched, total, mismatches


def recover_one_incremental_group(
    *,
    source_root: Path,
    manifest_path: Path,
    groups: list[dict[str, object]],
    generated_postimages: dict[str, str],
) -> dict[str, object] | None:
    final_postimages: dict[str, str] = {}
    for group in groups:
        final_postimages.update(
            {
                str(relative): str(digest)
                for relative, digest in group["postimageSHA256"].items()
            }
        )

    candidates: list[dict[str, object]] = []
    for group in groups:
        preimages = group.get("incrementalPreimageSHA256", {})
        if not isinstance(preimages, dict) or not preimages:
            continue
        if all(
            (source_root / str(relative)).is_file()
            and sha256(source_root / str(relative)) == str(digest)
            for relative, digest in preimages.items()
        ):
            candidates.append(group)
    if not candidates:
        return None
    if len(candidates) != 1:
        raise PatchApplicationError(
            "Incremental recovery is ambiguous: multiple reviewed preimages match"
        )

    candidate = candidates[0]
    candidate_preimages = {
        str(relative): str(digest)
        for relative, digest in
        candidate["incrementalPreimageSHA256"].items()
    }
    for relative, expected in final_postimages.items():
        if relative in candidate_preimages:
            continue
        path = source_root / relative
        actual = sha256(path) if path.is_file() else "missing"
        accepted = {
            expected,
            *(
                [generated_postimages[relative]]
                if relative in generated_postimages
                else []
            ),
        }
        if actual not in accepted:
            raise PatchApplicationError(
                "Incremental recovery refused because an unrelated locked "
                f"postimage drifted: {relative}"
            )

    patch_path = manifest_path.parent / str(candidate["patchFile"])
    run_git_apply(source_root, [patch_path], "--check")
    run_git_apply(source_root, [patch_path])
    matched, total, mismatches = postimage_state(
        source_root,
        groups,
        generated_postimages,
    )
    if matched != total:
        raise PatchApplicationError(
            "Incremental recovery did not produce the complete reviewed "
            f"postimage set: {matched}/{total} match.\n"
            + "\n".join(mismatches[:12])
        )
    return {
        "status": "incrementally-recovered",
        "patchCount": 1,
        "postimageCount": total,
        "group": str(candidate["id"]),
    }


def apply_patchset(
    *,
    source_root: Path,
    manifest_path: Path = MANIFEST_PATH,
    rebase_plan_path: Path = REBASE_PLAN_PATH,
    check_only: bool = False,
    recover_incremental: bool = False,
) -> dict[str, object]:
    source_root = source_root.resolve()
    if not source_root.is_dir():
        raise PatchApplicationError(f"Chromium source root is missing: {source_root}")

    summary = VERIFIER.verify_manifest(
        manifest_path=manifest_path,
        rebase_plan_path=rebase_plan_path,
        release=True,
        verify_source_evidence=True,
        project_root=PROJECT_ROOT,
    )
    expected_version = str(summary["targetChromiumVersion"])
    actual_version = chromium_version(source_root)
    if actual_version != expected_version:
        raise PatchApplicationError(
            f"Chromium version mismatch: expected {expected_version}, actual {actual_version}"
        )

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    groups = manifest["patchGroups"]
    generated_postimages: dict[str, str] = {}
    for generated_input in manifest["generatedInputs"]:
        generated_postimages.update(
            {
                str(path): str(digest)
                for path, digest in
                generated_input["postimageSHA256"].items()
            }
        )
    patch_paths = [
        manifest_path.parent / str(group["patchFile"])
        for group in groups
    ]
    matched, total, mismatches = postimage_state(
        source_root,
        groups,
        generated_postimages,
    )
    if matched == total:
        return {
            "status": "already-applied",
            "patchCount": len(patch_paths),
            "postimageCount": total,
            "chromiumVersion": actual_version,
        }
    try:
        run_git_apply(source_root, patch_paths, "--check")
    except PatchApplicationError as forward_error:
        if recover_incremental and not check_only:
            recovered = recover_one_incremental_group(
                source_root=source_root,
                manifest_path=manifest_path,
                groups=groups,
                generated_postimages=generated_postimages,
            )
            if recovered is not None:
                return {
                    **recovered,
                    "chromiumVersion": actual_version,
                }
        try:
            run_git_apply(source_root, patch_paths, "--reverse", "--check")
        except PatchApplicationError:
            raise PatchApplicationError(
                "Owned patchset is partially applied or its preimage drifted.\n"
                + "\n".join(mismatches[:12])
            ) from forward_error
        raise PatchApplicationError(
            "Patch contents appear applied, but locked postimages do not match.\n"
            + "\n".join(mismatches[:12])
        ) from forward_error
    if check_only:
        return {
            "status": "ready-to-apply",
            "patchCount": len(patch_paths),
            "postimageCount": total,
            "chromiumVersion": actual_version,
        }

    run_git_apply(source_root, patch_paths)
    matched, total, mismatches = postimage_state(
        source_root,
        groups,
        generated_postimages,
    )
    if matched != total:
        raise PatchApplicationError(
            f"Postimage verification failed after apply: {matched}/{total} match.\n"
            + "\n".join(mismatches[:12])
        )
    return {
        "status": "applied",
        "patchCount": len(patch_paths),
        "postimageCount": total,
        "chromiumVersion": actual_version,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Atomically apply and verify the owned NeAntik Chromium patch series.",
    )
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--manifest", type=Path, default=MANIFEST_PATH)
    parser.add_argument("--rebase-plan", type=Path, default=REBASE_PLAN_PATH)
    parser.add_argument("--check", action="store_true")
    parser.add_argument(
        "--recover-incremental",
        action="store_true",
        help=(
            "Apply one manifest group only when its explicit incremental "
            "preimage matches and every unrelated final postimage is exact."
        ),
    )
    args = parser.parse_args()
    try:
        result = apply_patchset(
            source_root=args.source_root,
            manifest_path=args.manifest.resolve(),
            rebase_plan_path=args.rebase_plan.resolve(),
            check_only=args.check,
            recover_incremental=args.recover_incremental,
        )
    except (PatchApplicationError, VERIFIER.PatchsetManifestError) as error:
        print(f"NeAntik patchset application failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
