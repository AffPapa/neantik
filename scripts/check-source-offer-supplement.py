#!/usr/bin/env python3
"""Read-only integrity check for a draft source-offer supplement."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
from pathlib import Path, PurePosixPath


HEX = re.compile(r"^[0-9a-f]{64}$")
LOCAL_PATH_MARKERS = tuple(
    marker for marker in (str(Path.home()), str(Path.cwd()), tempfile.gettempdir())
    if marker and marker != "/"
)


class SupplementError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(root: Path, value: object, label: str) -> Path:
    if not isinstance(value, str) or not value or "\\" in value:
        raise SupplementError(f"invalid relative path: {label}")
    parts = PurePosixPath(value).parts
    if value.startswith("/") or any(part in {"", ".", ".."} for part in parts):
        raise SupplementError(f"unsafe relative path: {label}")
    path = root
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise SupplementError(f"symlinked path: {label}")
    if not path.is_file():
        raise SupplementError(f"missing or unsafe file: {label}")
    return path


def verify(base_root: Path, supplement_root: Path) -> dict:
    if base_root.is_symlink() or not base_root.is_absolute() or not base_root.is_dir():
        raise SupplementError("base offer root must be an absolute, non-symlinked directory")
    if supplement_root.is_symlink() or not supplement_root.is_absolute() or not supplement_root.is_dir():
        raise SupplementError("supplement root must be an absolute, non-symlinked directory")
    base_root = base_root.resolve()
    supplement_root = supplement_root.resolve()
    manifest_path = supplement_root / "supplement-manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise SupplementError("supplement manifest is missing or unsafe")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SupplementError("supplement manifest is invalid JSON") from error
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise SupplementError("supplement declaration/status mismatch")
    if any(marker in manifest_path.read_text(encoding="utf-8") for marker in LOCAL_PATH_MARKERS):
        raise SupplementError("supplement manifest contains a local absolute path")

    base = manifest.get("baseOffer")
    if not isinstance(base, dict):
        raise SupplementError("frozen base offer declaration is missing")
    offer_id = base.get("offerId")
    expected_status = (
        f"DRAFT_SUPPLEMENT_TO_{offer_id}; NOT_A_COMPLETE_SOURCE_OFFER; NOT_CANDIDATE_BOUND"
        if offer_id in {"V246", "V382"} else None
    )
    if (expected_status is None or manifest.get("status") != expected_status
            or manifest.get("releaseQualified") is not False):
        raise SupplementError("supplement declaration/status mismatch")
    base_manifest = safe_relative(base_root, base.get("manifestPath"), "base manifest")
    archive = safe_relative(base_root, base.get("sourceArchivePath"), "base source archive")
    for path, key, label in (
            (base_manifest, "manifestSHA256", "base manifest"),
            (archive, "sourceArchiveSHA256", "base source archive")):
        expected = base.get(key)
        if not isinstance(expected, str) or not HEX.fullmatch(expected) or sha256(path) != expected:
            raise SupplementError(f"{label} hash mismatch")
    if offer_id == "V382":
        try:
            base_document = json.loads(base_manifest.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise SupplementError("V382 base offer manifest is invalid") from error
        if (base_document.get("currentWebKitV382FilteredModelSource", {}).get("derivedArchiveSHA256")
                != base.get("sourceArchiveSHA256")):
            raise SupplementError("V382 base manifest does not bind the declared source archive")

    components = manifest.get("supplementComponents")
    if not isinstance(components, list) or not components:
        raise SupplementError("supplement components are missing")
    seen: set[str] = set()
    total_bytes = 0
    for item in components:
        if not isinstance(item, dict):
            raise SupplementError("invalid supplement component")
        relative = item.get("path")
        if not isinstance(relative, str) or relative in seen:
            raise SupplementError("duplicate or invalid supplement component path")
        seen.add(relative)
        path = safe_relative(supplement_root, relative, "supplement component")
        expected_sha = item.get("sha256")
        expected_size = item.get("bytes")
        if (not isinstance(expected_sha, str) or not HEX.fullmatch(expected_sha) or
                not isinstance(expected_size, int) or expected_size < 0 or
                path.stat().st_size != expected_size or sha256(path) != expected_sha):
            raise SupplementError(f"supplement component hash/size mismatch: {relative}")
        content = path.read_bytes()
        if any(marker.encode("utf-8") in content for marker in LOCAL_PATH_MARKERS):
            raise SupplementError(f"supplement payload contains a local absolute path: {relative}")
        total_bytes += expected_size

    return {
        "status": "SUPPLEMENT_INTEGRITY_PASS; COMPLETE_SOURCE_OFFER_NOT_PROVED",
        "supplementManifestSHA256": sha256(manifest_path),
        "baseManifestSHA256": base["manifestSHA256"],
        "baseSourceArchiveSHA256": base["sourceArchiveSHA256"],
        "baseOfferID": offer_id,
        "componentCount": len(components),
        "componentBytes": total_bytes,
        "completeSourceOffer": False,
        "releaseQualified": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-offer-root", type=Path, required=True)
    parser.add_argument("--supplement-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = verify(args.base_offer_root, args.supplement_root)
    except (OSError, SupplementError) as error:
        print(f"Source-offer supplement check failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
