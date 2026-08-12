#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Callable
from contextlib import contextmanager
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


class PostimageValidationError(PatchApplicationError):
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


def touched_patch_paths(patch_paths: list[Path]) -> list[Path]:
    paths: set[Path] = set()
    header = re.compile(r"^(?:---|\+\+\+) (?:a|b)/(.+)$")
    for patch_path in patch_paths:
        try:
            lines = patch_path.read_text(encoding="utf-8").splitlines()
        except OSError as error:
            raise PatchApplicationError(f"Cannot read patch {patch_path}: {error}") from error
        for line in lines:
            match = header.match(line)
            if match is None:
                continue
            relative = Path(match.group(1))
            if relative.is_absolute() or ".." in relative.parts:
                raise PatchApplicationError(
                    f"Owned patch contains an unsafe path: {relative}"
                )
            paths.add(relative)
    if not paths:
        raise PatchApplicationError("Owned patch series has no file paths")
    return sorted(paths)


def copy_regular_file(source: Path, destination: Path) -> None:
    if source.is_symlink() or (source.exists() and not source.is_file()):
        raise PatchApplicationError(
            f"Owned patch transaction supports regular files only: {source}"
        )
    if not source.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def verify_safe_transaction_path(source_root: Path, relative: Path) -> None:
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        raise PatchApplicationError(
            f"Owned patch contains an unsafe path: {relative}"
        )
    try:
        root = source_root.resolve(strict=True)
    except OSError as error:
        raise PatchApplicationError(
            f"Owned patch transaction root is unavailable: {source_root}"
        ) from error
    if source_root.is_symlink() or not root.is_dir():
        raise PatchApplicationError(
            f"Owned patch transaction root must be a regular directory: {source_root}"
        )

    current = root
    for component in relative.parts[:-1]:
        current /= component
        try:
            mode = os.lstat(current).st_mode
        except FileNotFoundError:
            break
        except OSError as error:
            raise PatchApplicationError(
                f"Cannot inspect owned patch path: {current}"
            ) from error
        if stat.S_ISLNK(mode):
            raise PatchApplicationError(
                f"Owned patch path contains a symlinked directory: {current}"
            )
        if not stat.S_ISDIR(mode):
            raise PatchApplicationError(
                f"Owned patch path parent is not a directory: {current}"
            )

    candidate = root / relative
    if candidate.is_symlink():
        raise PatchApplicationError(
            f"Owned patch transaction refuses symlink targets: {candidate}"
        )
    resolved = candidate.resolve(strict=False)
    if resolved != root and root not in resolved.parents:
        raise PatchApplicationError(
            f"Owned patch path escapes the transaction root: {relative}"
        )


def file_state(path: Path) -> tuple[str, int] | None:
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file():
        raise PatchApplicationError(
            f"Owned patch transaction supports regular files only: {path}"
        )
    return sha256(path), path.stat().st_mode & 0o777


def restore_snapshot(
    *,
    source_root: Path,
    snapshot_root: Path,
    relative_paths: list[Path],
) -> None:
    for relative in relative_paths:
        verify_safe_transaction_path(snapshot_root, relative)
        verify_safe_transaction_path(source_root, relative)
        source = snapshot_root / relative
        destination = source_root / relative
        if source.is_symlink():
            raise PatchApplicationError(
                f"Owned patch transaction refuses symlink snapshots: {source}"
            )
        if source.is_file():
            destination.parent.mkdir(parents=True, exist_ok=True)
            verify_safe_transaction_path(source_root, relative)
            temporary = destination.with_name(
                f".{destination.name}.neantik-restore-{uuid.uuid4().hex}"
            )
            try:
                shutil.copy2(source, temporary)
                verify_safe_transaction_path(source_root, relative)
                os.replace(temporary, destination)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        elif destination.exists() or destination.is_symlink():
            verify_safe_transaction_path(source_root, relative)
            destination.unlink()


@contextmanager
def exclusive_transaction_lock(source_root: Path):
    lock_path = source_root.parent / f".{source_root.name}.neantik-patch.lock"
    flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise PatchApplicationError(
            f"Cannot open owned patch transaction lock: {lock_path}"
        ) from error
    try:
        mode = os.fstat(descriptor).st_mode
        if not stat.S_ISREG(mode):
            raise PatchApplicationError(
                f"Owned patch transaction lock is not a regular file: {lock_path}"
            )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise PatchApplicationError(
                "Chromium source is already locked by another owned patch "
                f"transaction: {source_root}"
            ) from error
        yield
    finally:
        os.close(descriptor)


def _run_patch_series_transaction_locked(
    source_root: Path,
    patch_paths: list[Path],
    *,
    check_only: bool,
    reverse: bool = False,
    validate_commit: Callable[[], None] | None = None,
) -> None:
    relative_paths = touched_patch_paths(patch_paths)
    with tempfile.TemporaryDirectory(prefix="neantik-patch-transaction-") as raw:
        transaction_root = Path(raw)
        snapshot_root = transaction_root / "before"
        work_root = transaction_root / "work"
        snapshot_root.mkdir()
        work_root.mkdir()
        for relative in relative_paths:
            verify_safe_transaction_path(source_root, relative)
            copy_regular_file(source_root / relative, snapshot_root / relative)
            copy_regular_file(source_root / relative, work_root / relative)

        ordered_patch_paths = (
            list(reversed(patch_paths)) if reverse else patch_paths
        )
        options = ("--reverse",) if reverse else ()
        for patch_path in ordered_patch_paths:
            run_git_apply(work_root, [patch_path], *options, "--check")
            run_git_apply(work_root, [patch_path], *options)

        if check_only:
            return

        for relative in relative_paths:
            verify_safe_transaction_path(source_root, relative)
            if file_state(source_root / relative) != file_state(snapshot_root / relative):
                raise PatchApplicationError(
                    f"Chromium source changed during owned patch transaction: {relative}"
                )

        try:
            restore_snapshot(
                source_root=source_root,
                snapshot_root=work_root,
                relative_paths=relative_paths,
            )
            if validate_commit is not None:
                validate_commit()
        except BaseException as error:
            try:
                restore_snapshot(
                    source_root=source_root,
                    snapshot_root=snapshot_root,
                    relative_paths=relative_paths,
                )
            except (OSError, PatchApplicationError) as restore_error:
                raise PatchApplicationError(
                    "Owned patch transaction failed and its exact preimage "
                    f"could not be restored: transaction={error}; "
                    f"restore={restore_error}"
                ) from restore_error
            if isinstance(error, PostimageValidationError):
                raise
            raise PatchApplicationError(
                f"Owned patch transaction could not be committed: {error}"
            ) from error


def run_patch_series_transaction(
    source_root: Path,
    patch_paths: list[Path],
    *,
    check_only: bool,
    reverse: bool = False,
    validate_commit: Callable[[], None] | None = None,
) -> None:
    with exclusive_transaction_lock(source_root):
        _run_patch_series_transaction_locked(
            source_root,
            patch_paths,
            check_only=check_only,
            reverse=reverse,
            validate_commit=validate_commit,
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
    validation: dict[str, int] = {}

    def validate_incremental_commit() -> None:
        matched, total, mismatches = postimage_state(
            source_root,
            groups,
            generated_postimages,
        )
        validation["total"] = total
        if matched != total:
            raise PostimageValidationError(
                "Incremental recovery did not produce the complete reviewed "
                f"postimage set: {matched}/{total} match.\n"
                + "\n".join(mismatches[:12])
            )

    run_patch_series_transaction(
        source_root,
        [patch_path],
        check_only=False,
        validate_commit=validate_incremental_commit,
    )
    total = validation["total"]
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
    validation: dict[str, int] = {}

    def validate_full_commit() -> None:
        commit_matched, commit_total, commit_mismatches = postimage_state(
            source_root,
            groups,
            generated_postimages,
        )
        validation["total"] = commit_total
        if commit_matched != commit_total:
            raise PostimageValidationError(
                "Postimage verification failed after apply: "
                f"{commit_matched}/{commit_total} match.\n"
                + "\n".join(commit_mismatches[:12])
            )

    try:
        run_patch_series_transaction(
            source_root,
            patch_paths,
            check_only=check_only,
            validate_commit=None if check_only else validate_full_commit,
        )
    except PatchApplicationError as forward_error:
        if isinstance(forward_error, PostimageValidationError):
            raise
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

    total = validation["total"]
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
