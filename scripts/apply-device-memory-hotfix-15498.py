#!/usr/bin/env python3
"""Replay the two reviewed Device Memory fixes on the isolated M154.98 port."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    source, project = args.source.resolve(strict=True), args.project.resolve(strict=True)
    runtime = project / "runtime"
    data = json.loads((runtime / "chromium-154-device-memory-hotfix.json").read_text())
    if subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() != "b859317bf11f6be47f9b7799ec690a0a42a1fb33":
        raise ValueError("source HEAD is not the official .98 tag")
    if not args.report.is_absolute() or args.report.exists() or args.report.is_symlink():
        raise ValueError("report must be a new absolute non-symlink file")
    if args.report.resolve().is_relative_to(source) or args.report.resolve().is_relative_to(project):
        raise ValueError("report must be outside source repositories")
    fixes = {
        "content/browser/client_hints/client_hints.cc": "device-memory-client-hints.patch",
        "third_party/blink/renderer/core/loader/frame_fetch_context.cc": "device-memory-renderer-client-hints.patch",
    }
    records = []
    for item in data["files"]:
        relative = item["sourcePath"]
        if relative not in fixes:
            raise ValueError("unexpected Device Memory source path")
        target = source / relative
        patch = runtime / "nevision-patches/ports/chromium-154.0.8037.93/patches" / fixes[relative]
        if patch.is_symlink() or target.is_symlink() or sha(patch) != item["patchSHA256"] or sha(target) != item["preimageSHA256"]:
            raise ValueError(f"Device Memory preimage/patch mismatch: {relative}")
    for item in data["files"]:
        relative = item["sourcePath"]
        target = source / relative
        patch = runtime / "nevision-patches/ports/chromium-154.0.8037.93/patches" / fixes[relative]
        command = ["/usr/bin/patch", "--batch", "--forward", "--fuzz=0", "-p1",
                   "--no-backup-if-mismatch", "-d", str(source), "-i", str(patch)]
        dry = subprocess.run(command + ["--dry-run"], capture_output=True, text=True)
        if dry.returncode:
            raise ValueError(f"Device Memory patch dry-run failed: {relative}")
        applied = subprocess.run(command, capture_output=True, text=True)
        if applied.returncode or sha(target) != item["postimageSHA256"]:
            raise ValueError(f"Device Memory patch/postimage failed: {relative}")
        records.append({"sourcePath": relative, "preimageSHA256": item["preimageSHA256"],
                        "patchSHA256": item["patchSHA256"],
                        "postimageSHA256": item["postimageSHA256"]})
        print(f"PASS {relative}")
    args.report.write_text(json.dumps({"schemaVersion": 1, "targetVersion": "154.0.8037.98",
                                       "status": "diagnostic-source-hotfix", "releaseReady": False,
                                       "files": records}, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f"M154.98 Device Memory replay stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
