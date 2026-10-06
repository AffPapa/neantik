#!/usr/bin/env python3
"""Isolated, fail-closed M154.98 patch replay; diagnostic until qualified."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

VERSION = "154.0.8037.98"
COMMIT = "b859317bf11f6be47f9b7799ec690a0a42a1fb33"
TREE = "e3eac82f3bb5479e80ab245c514083b5db4fedf3"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root: Path, argument: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", argument], text=True
    ).strip()


def series(root: Path) -> list[Path]:
    names = [line.split()[0] for line in (root / "patches/series").read_text().splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    paths = []
    for name in names:
        path = root / "patches" / name
        if (path.is_symlink() or not path.is_file() or
                not path.resolve(strict=True).is_relative_to((root / "patches").resolve())):
            raise ValueError("patch series contains an unsafe path")
        recorded = subprocess.check_output(
            ["git", "-C", str(root), "show", f"HEAD:patches/{name}"])
        if hashlib.sha256(recorded).hexdigest() != digest(path):
            raise ValueError(f"patch bytes differ from pinned Git input: {name}")
        paths.append(path)
    return paths


def patch_targets(paths: list[Path], source: Path) -> list[str]:
    names: set[str] = set()
    for patch in paths:
        for line in patch.read_text(errors="replace").splitlines():
            match = re.match(r"^(?:--- a|\+\+\+ b)/(.+)$", line)
            if match is None:
                continue
            name = match.group(1).split("\t", 1)[0]
            parts = Path(name).parts
            if not parts or any(part in {".", ".."} for part in parts) or Path(name).is_absolute():
                raise ValueError(f"patch contains unsafe source path: {patch.name}")
            target = source / name
            if any(parent.is_symlink() for parent in (target, *target.parents)
                   if parent == source or parent.is_relative_to(source)):
                raise ValueError(f"patch targets a symlink: {name}")
            names.add(name)
    return sorted(names)


def inventory(source: Path, names: list[str]) -> str:
    records = []
    for name in names:
        path = source / name
        if path.is_symlink():
            raise ValueError(f"symlink appeared at patch target: {name}")
        records.append({"path": name, "sha256": digest(path) if path.is_file() else None})
    return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def nested_repositories(source: Path, names: list[str]) -> list[dict[str, str]]:
    roots: set[Path] = set()
    for name in names:
        parent = (source / name).parent
        while parent != source:
            if (parent / ".git").exists():
                roots.add(parent)
                break
            parent = parent.parent
    records = []
    for root in sorted(roots):
        if subprocess.check_output(["git", "-C", str(root), "status", "--porcelain",
                                    "--untracked-files=no"], text=True).strip():
            raise ValueError(f"nested dependency has tracked modifications: {root.relative_to(source)}")
        records.append({"path": root.relative_to(source).as_posix(), "commit": git(root, "HEAD"),
                        "tree": git(root, "HEAD^{tree}")})
    return records


def write_report(path: Path, document: dict[str, object]) -> None:
    descriptor, temp_name = tempfile.mkstemp(prefix="replay-15498-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def apply(source: Path, patch: Path, label: str) -> dict[str, str]:
    command = ["/usr/bin/patch", "--batch", "--forward", "--fuzz=0", "-p1",
               "--ignore-whitespace", "--no-backup-if-mismatch", "-d", str(source),
               "-i", str(patch)]
    check = subprocess.run(command + ["--dry-run"], capture_output=True, text=True)
    if check.returncode:
        raise ValueError(f"{label}: dry-run failed: {(check.stdout + check.stderr)[-900:]}")
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"{label}: apply failed: {(result.stdout + result.stderr)[-900:]}")
    output = result.stdout + result.stderr
    return {"label": label, "patchSHA256": digest(patch),
            "applyOutputSHA256": hashlib.sha256(output.encode()).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("common", type=Path)
    parser.add_argument("mac", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source, common, mac, project = (path.resolve(strict=True) for path in
                                     (args.source, args.common, args.mac, args.project))
    if git(source, "HEAD") != COMMIT or git(source, "HEAD^{tree}") != TREE:
        raise ValueError("source commit/tree differs from official Chromium .98 tag")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain",
                                "--untracked-files=no"], text=True).strip():
        raise ValueError("source has tracked modifications before replay")
    plan = json.loads((project / "runtime/chromium-154-rebase-plan.json").read_text())
    for root, info, label in ((common, plan["upstreamCommonOverlay"], "common"),
                              (mac, plan["upstreamMacPackaging"], "mac")):
        if (git(root, "HEAD"), git(root, "HEAD^{tree}")) != (info["commit"], info["tree"]):
            raise ValueError(f"{label} source commit/tree differs from pinned input")
        if subprocess.check_output(["git", "-C", str(root), "status", "--porcelain",
                                    "--untracked-files=no"], text=True).strip():
            raise ValueError(f"{label} has tracked modifications")
        if digest(root / "patches/series") != info["seriesSHA256"]:
            raise ValueError(f"{label} patch series digest differs from pinned input")
    version_lines = dict(line.split("=", 1) for line in
                         (source / "chrome/VERSION").read_text().splitlines() if "=" in line)
    if ".".join(version_lines[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH")) != VERSION:
        raise ValueError("source VERSION does not match target")
    owned_root = project / "runtime/nevision-patches/ports/chromium-154.0.8037.93"
    owned = plan["ownedPort"]["patches"]
    old_experiment = json.loads((owned_root / "port-experiment.json").read_text())
    expected_pruning_sha = old_experiment["upstreamCommonOverlay"]["pruningListSHA256"]
    pruning_source = common / "pruning.list"
    if pruning_source.is_symlink() or digest(pruning_source) != expected_pruning_sha:
        raise ValueError("common pruning list differs from reviewed input")
    common_patches, mac_patches = series(common), series(mac)
    owned_patches = []
    for item in owned:
        path = owned_root / item["path"]
        if (path.is_symlink() or not path.is_file() or
                not path.resolve(strict=True).is_relative_to(owned_root.resolve()) or
                digest(path) != item["sha256"]):
            raise ValueError(f"owned patch input mismatch: {item['id']}")
        owned_patches.append(path)
    names = patch_targets(common_patches + mac_patches + owned_patches, source)
    nested = nested_repositories(source, names)
    if not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        raise ValueError("output must be a new absolute non-symlink file")
    output = args.output
    if any(parent.is_symlink() for parent in output.parents):
        raise ValueError("output has a symlinked parent")
    if any(output.is_relative_to(root) for root in (source, common, mac, project)):
        raise ValueError("output must be outside all source repositories")
    output.parent.mkdir(parents=True, exist_ok=True)
    pruning_output = output.with_name(output.stem + "-pruning-present.list")
    if pruning_output.exists() or pruning_output.is_symlink():
        raise ValueError("pruning output already exists")
    present: list[str] = []
    for name in pruning_source.read_text().splitlines():
        path = Path(name)
        if not name or path.is_absolute() or any(part in {".", ".."} for part in path.parts):
            raise ValueError("common pruning list contains an unsafe path")
        candidate = source / path
        if any(parent.is_symlink() for parent in candidate.parents
               if parent == source or parent.is_relative_to(source)):
            raise ValueError("pruning list crosses a symlink")
        if candidate.exists() or candidate.is_symlink():
            if candidate.is_dir() and not candidate.is_symlink():
                raise ValueError("pruning list names a directory")
            present.append(name)
    with pruning_output.open("x", encoding="utf-8") as stream:
        stream.write("\n".join(present) + "\n")
    prune_result = subprocess.run(
        [sys.executable, str(common / "utils/prune_binaries.py"), str(source),
         str(pruning_output), "--keep-contingent-paths"], capture_output=True, text=True)
    if prune_result.returncode:
        raise ValueError(f"reviewed pruning failed: {(prune_result.stdout + prune_result.stderr)[-900:]}")
    before = inventory(source, names)
    records: list[dict[str, str]] = []
    failure: Exception | None = None
    try:
        for label, paths in (("common", common_patches), ("mac", mac_patches)):
            for index, path in enumerate(paths, 1):
                records.append(apply(source, path, f"{label}:{index}:{path.name}"))
                print(records[-1]["label"], flush=True)
        for item, path in zip(owned, owned_patches):
            records.append(apply(source, path, f"owned:{item['order']}:{item['id']}"))
            print(records[-1]["label"], flush=True)
    except Exception as error:
        failure = error
    finally:
        try:
            postimage = inventory(source, names)
        except Exception as inventory_error:
            postimage = None
            if failure is None:
                failure = inventory_error
        rejected = [name + suffix for name in names for suffix in (".rej", ".orig")
                    if (source / (name + suffix)).exists()]
        document = {"schemaVersion": 1, "targetVersion": VERSION,
                    "sourceCommit": COMMIT, "sourceTree": TREE,
                    "pruningSourceSHA256": expected_pruning_sha,
                    "presentPruningSHA256": digest(pruning_output),
                    "presentPruningCount": len(present),
                    "nestedInputRepositories": nested,
                    "inputTargetDigest": before, "postimageTargetDigest": postimage,
                    "targetCount": len(names), "applied": records,
                    "replayComplete": failure is None and len(records) == 202 and not rejected,
                    "releaseReady": False,
                    "status": "diagnostic-replay" if failure is None else "tainted-after-failed-replay",
                    "qualificationLimit": "Patch-command result only; full source snapshot, build and runtime qualification remain separate.",
                    "rejectedArtifactsInTargets": rejected}
        try:
            write_report(output, document)
        except OSError as report_error:
            if failure is None:
                raise
            print(f"report write also failed: {report_error}", file=sys.stderr)
    if failure is not None:
        raise failure
    if len(records) != 202:
        raise ValueError("expected 109 common, 20 mac and 73 owned patches")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, KeyError, ValueError) as error:
        print(f"M154.98 replay stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
