#!/usr/bin/env python3
"""Assemble or verify the CMake-scoped WebRTC notice research candidate.

This tool does not make a license election, approve redistribution, or modify
an app/runtime package. It copies only notice files hash-bound by the retained
WebRTC CMake source/link receipts.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_COMMIT = "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
DEFAULT_SOURCE = Path("/private/tmp/neantik-webkit-upstream-324120")
DEFAULT_OUTPUT = ROOT / "docs/evidence/third-party/webkit-v16-webrtc-notices-cmake-candidate"
DEFAULT_RECEIPTS = (
    ROOT / "docs/evidence/webkit-webrtc-link-closure-notices-v2-20261020.json",
    ROOT / "docs/evidence/webkit-webrtc-selected-archive-notices-20261020.json",
)
DEFAULT_SOURCE_MAP = ROOT / "docs/evidence/webkit-third-party-object-license-map-20261020.json"


class CandidateError(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_source_path(raw: object) -> PurePosixPath:
    if not isinstance(raw, str) or not raw:
        raise CandidateError("notice sourcePath must be a non-empty string")
    rel = PurePosixPath(raw)
    if rel.is_absolute() or any(part in ("", ".", "..") for part in rel.parts):
        raise CandidateError(f"unsafe notice sourcePath: {raw!r}")
    return rel


def collect_notices(
    *,
    source_root: Path,
    receipt_paths: tuple[Path, ...],
    upstream_commit: str,
) -> list[dict[str, Any]]:
    notices: dict[str, dict[str, Any]] = {}
    resolved_root = source_root.resolve(strict=True)
    for receipt_path in receipt_paths:
        try:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise CandidateError(f"cannot read receipt {receipt_path}: {error}") from error
        if receipt.get("upstreamCommit") != upstream_commit:
            raise CandidateError(f"receipt commit mismatch: {receipt_path}")
        files = receipt.get("noticeFiles")
        if not isinstance(files, list):
            raise CandidateError(f"receipt has no noticeFiles list: {receipt_path}")
        for item in files:
            if not isinstance(item, dict):
                raise CandidateError(f"invalid notice record in {receipt_path}")
            rel = safe_source_path(item.get("sourcePath"))
            source = source_root.joinpath(*rel.parts)
            if source.is_symlink() or not source.is_file():
                raise CandidateError(f"notice is not a regular file: {rel}")
            if not source.resolve(strict=True).is_relative_to(resolved_root):
                raise CandidateError(f"notice resolves outside its source path: {rel}")
            data = source.read_bytes()
            actual_hash = sha256(data)
            if item.get("sha256") != actual_hash:
                raise CandidateError(f"notice SHA-256 mismatch: {rel}")
            if type(item.get("bytes")) is not int or item["bytes"] != len(data):
                raise CandidateError(f"notice byte count mismatch: {rel}")
            entry = {
                "sourcePath": rel.as_posix(),
                "outputPath": f"files/{rel.as_posix()}",
                "sha256": actual_hash,
                "bytes": len(data),
                "receipt": receipt_path.name,
                "scope": item.get("scope", item.get("selectedArchives", [])),
            }
            prior = notices.get(rel.as_posix())
            if prior and (prior["sha256"] != actual_hash or prior["bytes"] != len(data)):
                raise CandidateError(f"conflicting receipt records: {rel}")
            notices[rel.as_posix()] = entry
    return [notices[key] for key in sorted(notices)]


def render_manifest(
    *,
    upstream_commit: str,
    receipt_paths: tuple[Path, ...],
    notices: list[dict[str, Any]],
) -> bytes:
    manifest = {
        "schemaVersion": 1,
        "status": "research candidate; not a complete notice bundle, legal opinion, or redistribution approval",
        "upstream": {"repository": "WebKit/WebKit", "commit": upstream_commit},
        "buildScope": "pinned CMake libwebrtc.dylib link/source receipts; includes mapped direct-source notices and selected static-archive notices",
        "inputs": [path.relative_to(ROOT).as_posix() for path in receipt_paths],
        "noticeCount": len(notices),
        "notices": notices,
        "limitations": [
            "GN-generated LICENSE_THIRD_PARTY is not applicable to this CMake build output.",
            "The CMake-derived candidate still requires review for full source/header/generated-input coverage.",
            "This does not close WebCore/PAL/ANGLE or runtime resources.",
            "LGPL corresponding-source and replacement/relink obligations remain open.",
            "No runtime package was modified.",
        ],
    }
    return (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def validate_source_group_coverage(
    *,
    coverage_receipt: Path,
    notices: list[dict[str, Any]],
    upstream_commit: str,
) -> dict[str, int]:
    try:
        coverage = json.loads(coverage_receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CandidateError(f"cannot read source coverage receipt {coverage_receipt}: {error}") from error
    if coverage.get("upstreamCommit") != upstream_commit:
        raise CandidateError("source coverage receipt commit mismatch")
    groups = coverage.get("sourceLicenseGroups")
    if not isinstance(groups, list) or not groups:
        raise CandidateError("source coverage receipt has no sourceLicenseGroups")
    notice_paths = {item["sourcePath"] for item in notices}
    required_paths: set[str] = set()
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("sourceDirectory"), str):
            raise CandidateError("invalid source license group")
        files = group.get("noticeFiles")
        if not isinstance(files, list) or not files:
            raise CandidateError("source license group has no noticeFiles")
        directory = safe_source_path(group["sourceDirectory"])
        for filename in files:
            leaf = safe_source_path(filename)
            if len(leaf.parts) != 1:
                raise CandidateError(f"source notice name must be a direct child: {filename}")
            required_paths.add((directory / leaf).as_posix())
    missing = sorted(required_paths - notice_paths)
    if missing:
        raise CandidateError("candidate omits source group notices: " + ", ".join(missing))
    return {"groups": len(groups), "requiredNoticePaths": len(required_paths), "coveredNoticePaths": len(required_paths)}


def verify_output(output: Path, expected_manifest: bytes, notices: list[dict[str, Any]]) -> None:
    if output.is_symlink() or not output.is_dir():
        raise CandidateError(f"candidate directory is missing or unsafe: {output}")
    manifest_path = output / "MANIFEST.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise CandidateError("candidate MANIFEST.json is missing or unsafe")
    if manifest_path.read_bytes() != expected_manifest:
        raise CandidateError("candidate manifest drifted; refusing to treat it as verified")
    for notice in notices:
        path = output / notice["outputPath"]
        if path.is_symlink() or not path.is_file():
            raise CandidateError(f"candidate notice is missing or unsafe: {notice['outputPath']}")
        data = path.read_bytes()
        if len(data) != notice["bytes"] or sha256(data) != notice["sha256"]:
            raise CandidateError(f"candidate notice drifted: {notice['outputPath']}")
    expected_paths = {"MANIFEST.json", *(item["outputPath"] for item in notices)}
    actual_paths = {
        path.relative_to(output).as_posix()
        for path in output.rglob("*")
        if path.is_file()
    }
    if actual_paths != expected_paths:
        raise CandidateError("candidate contains missing or untracked files")


def resolve_extra_receipts(paths: list[Path], *, root: Path = ROOT) -> tuple[Path, ...]:
    resolved_root = root.resolve(strict=True)
    result: list[Path] = []
    for receipt_path in paths:
        if receipt_path.is_symlink() or not receipt_path.is_file():
            raise CandidateError(f"extra receipt is missing or unsafe: {receipt_path}")
        resolved = receipt_path.resolve(strict=True)
        if not resolved.is_relative_to(resolved_root):
            raise CandidateError("extra receipts must be inside the repository")
        result.append(resolved)
    return tuple(result)


def assemble(output: Path, expected_manifest: bytes, notices: list[dict[str, Any]], source_root: Path) -> None:
    if output.exists() or output.is_symlink():
        raise CandidateError(f"refusing to overwrite existing candidate: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temp_root = Path(tempfile.mkdtemp(prefix="webkit-notices-", dir=output.parent))
    staged = temp_root / "candidate"
    try:
        for item in notices:
            rel = PurePosixPath(item["sourcePath"])
            source = source_root.joinpath(*rel.parts)
            destination = staged / "files" / Path(*rel.parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination, follow_symlinks=False)
        (staged / "MANIFEST.json").write_bytes(expected_manifest)
        verify_output(staged, expected_manifest, notices)
        os.rename(staged, output)
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--extra-receipt",
        type=Path,
        action="append",
        default=[],
        help="include an additional hash-bound source notice receipt under the repository",
    )
    parser.add_argument("--check", action="store_true", help="verify an existing candidate without writing")
    args = parser.parse_args(argv)
    # Preserve the final path component so an existing destination symlink is
    # detected by assemble()/verify_output() instead of silently followed.
    output = Path(os.path.abspath(args.output))
    try:
        commit = subprocess.check_output(
            ["git", "-C", str(args.source_root), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.PIPE,
        ).strip()
        if commit != EXPECTED_COMMIT:
            raise CandidateError(f"pinned source commit mismatch: {commit}")
        receipt_paths = DEFAULT_RECEIPTS + resolve_extra_receipts(args.extra_receipt)
        notices = collect_notices(
            source_root=args.source_root,
            receipt_paths=receipt_paths,
            upstream_commit=commit,
        )
        source_coverage = validate_source_group_coverage(
            coverage_receipt=DEFAULT_SOURCE_MAP,
            notices=notices,
            upstream_commit=commit,
        )
        manifest = render_manifest(
            upstream_commit=commit,
            receipt_paths=receipt_paths,
            notices=notices,
        )
        if args.check:
            verify_output(output, manifest, notices)
        else:
            assemble(output, manifest, notices, args.source_root)
        print(json.dumps({"status": "verified" if args.check else "assembled", "noticeCount": len(notices), "sourceCoverage": source_coverage, "output": str(output), "manifestSHA256": sha256(manifest)}))
        return 0
    except (CandidateError, OSError, subprocess.CalledProcessError) as error:
        print(f"webkit notice candidate: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
