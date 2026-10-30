#!/usr/bin/env python3
"""Verify a private, pre-sign WebKit source/image binding without signing or launching."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


class BindingError(ValueError):
    pass


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def physical_file(root: Path, relative: str) -> Path:
    if root.is_symlink() or not root.is_dir():
        raise BindingError("unsafe evidence root")
    path = Path(relative)
    if not relative or path.is_absolute() or any(part in (".", "..") for part in path.parts):
        raise BindingError("unsafe relative path")
    current = root
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            raise BindingError("symlink in evidence path")
    if not current.is_file():
        raise BindingError("missing evidence file")
    return current


def checked_json(path: Path, expected: str) -> dict:
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise BindingError("pinned JSON hash mismatch")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise BindingError("expected JSON object")
    return value


def verify(draft_path: Path, expected_draft: str, build_root: Path, stage_root: Path,
           build_receipt_path: Path, stage_receipt_path: Path, offer_path: Path,
           evidence_root: Path) -> dict:
    draft = checked_json(draft_path, expected_draft)
    if (draft.get("schemaVersion") != 1 or draft.get("releaseQualified") is not False
            or draft.get("noticeEvidenceIsComplete") is not False
            or draft.get("productionV122PinsModified") is not False):
        raise BindingError("draft scope or status mismatch")
    build = checked_json(build_receipt_path, draft["buildReceiptSHA256"])
    stage = checked_json(stage_receipt_path, draft["stagingReceiptSHA256"])
    offer = checked_json(offer_path, draft["sourceOfferManifestSHA256"])
    if (offer["source"]["commit"] != draft["managerSourceCommit"]
            or build["inputs"]["webkitCommit"] != draft["webkitUpstreamCommit"]
            or build["inputs"]["sourceArchiveSHA256"] != draft["webkitSourceArchiveSHA256"]
            or build["inputs"]["mainSourcePatchSHA256"] != draft["mainPatchSHA256"]
            or build["inputs"]["v36PatchSHA256"] != draft["resourcePatchSHA256"]):
        raise BindingError("source identity mismatch")
    components = offer["sourceOfferComponents"]
    hashes = {x["sha256"] for x in components}
    required = {draft["webkitSourceArchiveSHA256"], draft["mainPatchSHA256"],
                draft["resourcePatchSHA256"], offer["source"]["sourceArchiveSHA256"]}
    if not required <= hashes:
        raise BindingError("source offer missing pinned source or patch")
    for expected in required:
        matches = [x for x in components if x["sha256"] == expected]
        if len(matches) != 1:
            raise BindingError("source offer input is not unique")
        row = matches[0]
        file = physical_file(offer_path.parent, row["path"])
        if (row.get("includedInOfferFolder") is not True
                or file.stat().st_size != row["bytes"] or digest(file) != expected):
            raise BindingError("source offer input changed")
    outputs = build["outputs"]
    if len(outputs) != 14 or draft.get("matchingRebuildOutputs") != 14:
        raise BindingError("rebuild output count mismatch")
    output_map = {}
    for row in outputs:
        file = physical_file(build_root, row["path"])
        if file.stat().st_size != row["bytes"] or digest(file) != row["sha256"]:
            raise BindingError("rebuild output changed")
        if row["path"] in output_map:
            raise BindingError("duplicate rebuild path")
        output_map[row["path"]] = row["sha256"]
    images = draft["stagedImages"]
    if len(images) != 16 or draft.get("stagedImagesCount") != 16:
        raise BindingError("staged image count mismatch")
    seen, bound = set(), set()
    for row in images:
        path = row["path"]
        if path in seen:
            raise BindingError("duplicate staged path")
        seen.add(path)
        file = physical_file(stage_root, path)
        if (file.stat().st_size != row["bytes"] or digest(file) != row["sha256"]
                or stage["machOSHA256"].get(path) != row["sha256"]):
            raise BindingError("staged image changed")
        references = row["rebuildOutputsWithSameBytes"]
        if not references and not (row["compatibilitySpanSeparateInput"] is True
                                   and path == "libswiftCompatibilitySpan.dylib"):
            raise BindingError("unbound staged image")
        if references and row["compatibilitySpanSeparateInput"] is not False:
            raise BindingError("inconsistent compatibility input")
        for ref in references:
            if output_map.get(ref) != row["sha256"]:
                raise BindingError("image to rebuild binding mismatch")
            bound.add(ref)
    if seen != set(stage["machOSHA256"]) or bound != set(output_map):
        raise BindingError("stage or rebuild coverage mismatch")
    for name, expected in draft["sourceEvidence"].items():
        if digest(physical_file(evidence_root, name)) != expected:
            raise BindingError("source evidence changed")
    for group in draft["partialImageNoticeEvidence"]:
        if (not set(group["imagePaths"]) <= seen
                or not set(group["sourceEvidence"]) <= set(draft["sourceEvidence"])):
            raise BindingError("notice evidence reference mismatch")
    return {"status": "PASS_PRIVATE_PRESIGN_BINDING_ONLY", "rebuildOutputs": len(outputs),
            "stagedImages": len(images), "sourceEvidence": len(draft["sourceEvidence"]),
            "partialNoticeGroups": len(draft["partialImageNoticeEvidence"]),
            "releaseQualified": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("draft", "build-root", "stage-root", "build-receipt", "stage-receipt",
                 "offer", "evidence-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--expected-draft-sha256", required=True)
    args = parser.parse_args()
    try:
        result = verify(args.draft, args.expected_draft_sha256, args.build_root,
                        args.stage_root, args.build_receipt, args.stage_receipt,
                        args.offer, args.evidence_root)
    except (BindingError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
