#!/usr/bin/env python3
"""Classify the reviewed NeAntik patch groups against Chromium 153.

An exact reverse apply means the current 153 source postimage contains the
reviewed patch without context drift. A failed reverse apply is deliberately
classified as rebase-required; this verifier never rewrites a patch or claims
that a failed group is equivalent.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SERIES_PATH = PROJECT_ROOT / "runtime" / "nevision-patches" / "series.json"
STATUS_PATH = PROJECT_ROOT / "runtime" / "chromium-153-port-status.json"


class MatrixError(ValueError):
    pass


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise MatrixError(f"{label} must be a JSON object")
    return value


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise MatrixError(result.stderr.strip() or "git verification failed")
    return result.stdout.strip()


def verify(source_root: Path, series_path: Path = SERIES_PATH, status_path: Path = STATUS_PATH) -> dict[str, Any]:
    source_root = source_root.resolve()
    if not source_root.is_absolute() or not source_root.is_dir() or source_root.is_symlink():
        raise MatrixError("source root must be an absolute non-symlink directory")
    series = load_json(series_path.resolve(), "NeAntik patch series")
    status = load_json(status_path.resolve(), "Chromium 153 port status")
    if status.get("targetChromiumVersion") != "153.0.8010.52":
        raise MatrixError("port status is not Chromium 153.0.8010.52")
    official = status.get("officialChromiumBase")
    if not isinstance(official, dict):
        raise MatrixError("port status has no official Chromium base")
    if git(source_root, "rev-parse", "HEAD") != official.get("commit"):
        raise MatrixError("source HEAD does not match official Chromium commit")
    if git(source_root, "rev-parse", "HEAD^{tree}") != official.get("tree"):
        raise MatrixError("source tree does not match official Chromium tree")
    groups = series.get("patchGroups")
    if not isinstance(groups, list) or not groups:
        raise MatrixError("patch series has no patch groups")

    entries: list[dict[str, Any]] = []
    for group in groups:
        if not isinstance(group, dict):
            raise MatrixError("patch series contains a non-object group")
        group_id = group.get("id")
        patch_file = group.get("patchFile")
        if not isinstance(group_id, str) or not group_id:
            raise MatrixError("patch group has no id")
        if not isinstance(patch_file, str) or not patch_file.startswith("patches/"):
            raise MatrixError(f"patch group {group_id} has an unsafe patch path")
        patch_path = PROJECT_ROOT / "runtime" / "nevision-patches" / patch_file
        if not patch_path.is_file() or patch_path.is_symlink():
            raise MatrixError(f"patch file is missing: {patch_file}")
        result = subprocess.run(
            ["git", "-C", str(source_root), "apply", "--reverse", "--check", str(patch_path)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        exact = result.returncode == 0
        entries.append(
            {
                "id": group_id,
                "releaseRequired": bool(group.get("releaseRequired")),
                "patchFile": patch_file,
                "status": "exact-reverse-apply" if exact else "rebase-required",
            }
        )

    required = [entry for entry in entries if entry["releaseRequired"]]
    release_ready = bool(required) and all(
        entry["status"] == "exact-reverse-apply" for entry in required
    )
    return {
        "schemaVersion": 1,
        "status": "patch-matrix-verified" if release_ready else "patch-rebase-required",
        "releaseReady": release_ready,
        "targetChromiumVersion": status["targetChromiumVersion"],
        "officialChromiumBase": status["officialChromiumBase"],
        "patchSeriesTarget": series.get("targetChromiumVersion"),
        "groups": entries,
        "policy": (
            "Reverse-apply classification only. Exact groups are not runtime or "
            "release qualification; rebase-required groups must be ported and "
            "reviewed against Chromium 153 before signing or publication."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args.source_root)
        output = args.output.resolve()
        if not output.is_absolute():
            raise MatrixError("output must be an absolute path")
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, delete=False) as temporary:
            json.dump(result, temporary, ensure_ascii=False, indent=2, sort_keys=True)
            temporary.write("\n")
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, output)
    except (OSError, MatrixError) as error:
        print(f"Chromium 153 patch matrix verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Chromium 153 patch matrix: {output}")
    print(f"Exact groups: {sum(item['status'] == 'exact-reverse-apply' for item in result['groups'])}")
    print(f"Rebase-required groups: {sum(item['status'] == 'rebase-required' for item in result['groups'])}")
    print(f"Release readiness: {str(result['releaseReady']).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
