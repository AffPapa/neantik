#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import runtime_source_provenance as provenance


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
        raise provenance.SourceProvenanceError(
            f"Git verification failed in {repository}: {detail}"
        )
    return completed.stdout.strip()


def verify(build_root: Path, project_root: Path) -> None:
    if not build_root.is_absolute():
        raise provenance.SourceProvenanceError("Build root must be absolute")
    build_root = build_root.resolve()
    project_root = project_root.resolve()
    common_root = build_root / "ungoogled-chromium"
    contract = provenance.verify_contract(project_root=project_root)

    mac_expected = contract["macPackaging"]
    common_expected = contract["commonChromium"]
    assert isinstance(mac_expected, dict)
    assert isinstance(common_expected, dict)
    provenance.verify_repository(
        build_root,
        mac_expected,
        label="macPackaging",
    )
    common = provenance.verify_repository(
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
        raise provenance.SourceProvenanceError(
            "macPackaging recorded common submodule commit is not locked"
        )

    tag_ref = f"refs/tags/{common_expected['tag']}"
    if (
        git_output(common_root, "rev-parse", tag_ref)
        != common_expected["tagObject"]
        or git_output(common_root, "rev-parse", f"{tag_ref}^{{}}")
        != common["commit"]
    ):
        raise provenance.SourceProvenanceError(
            "commonChromium tag object or peeled commit does not match contract"
        )

    common_status = git_output(
        common_root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
    )
    if common_status:
        raise provenance.SourceProvenanceError(
            "commonChromium checkout contains local or untracked changes"
        )
    mac_status = git_output(
        build_root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
    )
    if mac_status != "M ungoogled-chromium":
        raise provenance.SourceProvenanceError(
            "macPackaging checkout must only replace its pinned common submodule"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the exact owned Chromium rebase source pair.",
    )
    parser.add_argument("build_root", type=Path)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    args = parser.parse_args()
    try:
        verify(args.build_root, args.project_root)
    except provenance.SourceProvenanceError as error:
        print(str(error), file=sys.stderr)
        return 1
    print("Owned Chromium source pair verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
