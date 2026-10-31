#!/usr/bin/env python3
"""Verify replay of the pinned Chromium 153 owned macOS source port.

This gate compares a built source tree with a clean official Chromium
worktree to prove that the tracked port diff and its generated/untracked
inputs can be replayed. It deliberately makes no claim about a second
binary, runtime behavior, signing, notarization, publication, or release
readiness.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
STATUS_PATH = PROJECT_ROOT / "runtime" / "chromium-153-port-status.json"
EXPORTER_PATH = PROJECT_ROOT / "scripts" / "export-chromium-153-port-input-manifest.py"
EXCLUDED_PREFIXES = ("build", "out", "tools/gn")


class ReplayError(ValueError):
    pass


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReplayError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise ReplayError(f"{label} must be a JSON object")
    return value


def load_exporter() -> Any:
    spec = importlib.util.spec_from_file_location(
        "chromium_153_manifest_for_replay", EXPORTER_PATH
    )
    if spec is None or spec.loader is None:
        raise ReplayError("cannot load Chromium 153 manifest exporter")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise ReplayError(result.stderr.strip() or "git verification failed")
    return result.stdout.strip()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def path_free(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: path_free(child)
            for key, child in value.items()
            if key not in {"sourceRoot", "candidateAppPath", "argsGNPath"}
        }
    if isinstance(value, list):
        return [path_free(child) for child in value]
    if isinstance(value, str):
        if value.startswith(("/Users/", "/private/tmp/", "/var/folders/")):
            raise ReplayError("replay evidence contains a local path")
    return value


def source_summary(manifest: dict[str, Any]) -> dict[str, Any]:
    git_info = manifest.get("git")
    if not isinstance(git_info, dict):
        raise ReplayError("manifest has no git evidence")
    return {
        "commit": git_info.get("commit"),
        "tree": git_info.get("tree"),
        "trackedDiffSHA256": git_info.get("trackedDiffSHA256"),
        "trackedDiffBytes": git_info.get("trackedDiffBytes"),
        "untrackedInventorySHA256": manifest.get("untrackedInventorySHA256"),
        "untrackedFileCount": manifest.get("untrackedFileCount"),
    }


def verify(
    source_root: Path,
    replay_root: Path,
    status_path: Path = STATUS_PATH,
) -> dict[str, Any]:
    source_root = source_root.resolve()
    replay_root = replay_root.resolve()
    status_path = status_path.resolve()
    for root, label in ((source_root, "source root"), (replay_root, "replay root")):
        if not root.is_absolute() or not root.is_dir() or root.is_symlink():
            raise ReplayError(f"{label} must be an absolute non-symlink directory")
    status = load_json(status_path, "Chromium 153 port status")
    if status.get("schemaVersion") != 1:
        raise ReplayError("unsupported Chromium 153 port status schema")
    if status.get("targetChromiumVersion") != "153.0.8010.52":
        raise ReplayError("port status target is not Chromium 153.0.8010.52")
    official = status.get("officialChromiumBase")
    expected = status.get("localCandidateEvidence")
    if not isinstance(official, dict) or not isinstance(expected, dict):
        raise ReplayError("port status is missing official or candidate evidence")

    exporter = load_exporter()
    source = exporter.build_manifest(source_root, EXCLUDED_PREFIXES)
    replay = exporter.build_manifest(replay_root, EXCLUDED_PREFIXES)
    source_view = source_summary(source)
    replay_view = source_summary(replay)

    for label, view in (("source", source_view), ("replay", replay_view)):
        if view["commit"] != official.get("commit"):
            raise ReplayError(f"{label} HEAD does not match official Chromium commit")
        if view["tree"] != official.get("tree"):
            raise ReplayError(f"{label} tree does not match official Chromium tree")
        for key in (
            "trackedDiffSHA256",
            "untrackedInventorySHA256",
        ):
            if view[key] != expected.get(key):
                raise ReplayError(f"{label} evidence mismatch: {key}")
        if view["untrackedFileCount"] != expected.get("untrackedInputCount"):
            raise ReplayError(f"{label} evidence mismatch: untrackedFileCount")

    if source_view != replay_view:
        raise ReplayError("source and replay evidence differ")
    diff_check = git(replay_root, "diff", "--check")
    if diff_check:
        raise ReplayError("replay has whitespace errors in its tracked diff")
    rejection_files = [
        item
        for item in git(
            replay_root, "ls-files", "--others", "--exclude-standard"
        ).splitlines()
        if item.endswith((".rej", ".orig"))
    ]
    if rejection_files:
        raise ReplayError("replay contains patch rejection artifacts")

    result = {
        "schemaVersion": 1,
        "status": "source-replay-verified",
        "releaseReady": False,
        "targetArchitecture": "arm64",
        "targetChromiumVersion": status["targetChromiumVersion"],
        "officialChromiumBase": status["officialChromiumBase"],
        "source": source_view,
        "replay": replay_view,
        "sourceEvidenceSHA256": sha256_bytes(
            json.dumps(source_view, sort_keys=True, separators=(",", ":")).encode()
        ),
        "policy": (
            "Source replay evidence only. A second binary, runtime behavior, "
            "signing, notarization, publication, and release readiness remain "
            "unproven."
        ),
    }
    result = path_free(result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("replay_root", type=Path)
    parser.add_argument("--status", type=Path, default=STATUS_PATH)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args.source_root, args.replay_root, args.status)
        output = args.output.resolve()
        if not output.is_absolute():
            raise ReplayError("output must be an absolute path")
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=output.parent, delete=False
        ) as temporary:
            json.dump(result, temporary, ensure_ascii=False, indent=2, sort_keys=True)
            temporary.write("\n")
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, output)
    except (OSError, ReplayError) as error:
        print(f"Chromium 153 source replay verification failed: {error}", file=sys.stderr)
        return 1
    print(f"PASS: Chromium 153 source replay verified: {output}")
    print(f"Source evidence SHA-256: {result['sourceEvidenceSHA256']}")
    print("Release readiness: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
