#!/usr/bin/env python3
"""Apply the exact reviewed M155.40 overlay after its ordered patch replay."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
from runtime_locked_overlay import apply_overlay

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
parser.add_argument("postimages", type=Path)
parser.add_argument("replay_report", type=Path)
parser.add_argument("--report", required=True, type=Path)
args = parser.parse_args()
project = Path(__file__).resolve().parents[1]
lock_path = project / "runtime/chromium-15540-source-evidence/reviewed-source-overlay.json"
lock = json.loads(lock_path.read_text())
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
for field, ref in (("sourceCommit", "HEAD"), ("sourceTree", "HEAD^{tree}")):
    actual = subprocess.check_output(["git", "-C", str(args.source), "rev-parse", ref], text=True).strip()
    if actual != lock[field]:
        raise ValueError("M155.40 source identity mismatch")
if sha(args.replay_report) != lock["orderedReplaySHA256"]:
    raise ValueError("ordered replay report differs from reviewed input")
replay = json.loads(args.replay_report.read_text())
if replay.get("replayComplete") is not True or len(replay.get("records", [])) != 202:
    raise ValueError("M155.40 ordered replay is incomplete")
for item in lock["patches"] + lock["tupleRendererInputs"]:
    if sha(project / item["path"]) != item["sha256"]:
        raise ValueError("reviewed overlay input changed")
if sha(project / "runtime/apple-device-tuples.json") != lock["tupleCatalogSHA256"]:
    raise ValueError("tuple catalog changed")
if not args.report.is_absolute() or args.report.exists() or args.report.is_symlink():
    raise ValueError("report must be a new absolute file")
if not args.report.parent.is_dir() or any(parent.is_symlink() for parent in args.report.parents):
    raise ValueError("report parent must exist without symlinks")
if any(args.report.resolve().is_relative_to(root.resolve())
       for root in (args.source, args.postimages, project)):
    raise ValueError("report must be outside source, postimages and project")
document = dict(schemaVersion=1, targetVersion=lock["targetVersion"], releaseReady=False,
                status="reviewed-source-overlay-applied", overlayLockSHA256=sha(lock_path),
                files=lock["files"])
with args.report.open("x") as stream:
    reserved = os.fstat(stream.fileno())
    def commit_receipt():
        current = args.report.lstat()
        if (current.st_dev, current.st_ino) != (reserved.st_dev, reserved.st_ino):
            raise ValueError("reserved report was replaced")
        json.dump(document, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    try:
        apply_overlay(args.source, args.postimages, lock["files"], commit_receipt=commit_receipt)
    except BaseException:
        current = args.report.lstat()
        if (current.st_dev, current.st_ino) == (reserved.st_dev, reserved.st_ino):
            args.report.unlink()
        raise
print("PASS: exact M155.40 reviewed overlay applied; build/runtime qualification remains required.")
