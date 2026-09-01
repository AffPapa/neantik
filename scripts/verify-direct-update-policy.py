#!/usr/bin/env python3
from __future__ import annotations

import plistlib
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = PROJECT_ROOT / "Resources" / "Info.plist"
FORBIDDEN_INFO_KEYS = (
    "NeAntikUpdateChannelEnabled",
    "NeAntikUpdateAutoDownload",
    "NeAntikUpdateManifestURL",
    "NeAntikUpdatePublicKeyID",
    "NeAntikUpdatePublicKeyBase64",
)
FORBIDDEN_SOURCE_MARKERS = (
    "UpdateManifest",
    "UpdateChannelConfiguration",
    "NeAntikUpdate",
)


class UpdatePolicyError(ValueError):
    pass


def verify(
    *,
    info_plist: Path = INFO_PLIST,
    source_root: Path | None = None,
) -> str:
    with info_plist.open("rb") as handle:
        info = plistlib.load(handle)
    present_keys = [key for key in FORBIDDEN_INFO_KEYS if key in info]
    if present_keys:
        raise UpdatePolicyError(
            "Direct build must not contain dormant update configuration keys: "
            + ", ".join(present_keys)
        )

    resolved_source_root = source_root or (
        PROJECT_ROOT / "Sources/NeAntik"
    )
    if not resolved_source_root.is_dir():
        raise UpdatePolicyError(
            f"Direct source directory is missing: {resolved_source_root}"
        )
    update_source = resolved_source_root / "UpdateManifest.swift"
    if update_source.exists():
        raise UpdatePolicyError(
            "Direct build must not contain a dormant update implementation"
        )

    for source_path in resolved_source_root.glob("*.swift"):
        source = source_path.read_text(encoding="utf-8")
        for marker in FORBIDDEN_SOURCE_MARKERS:
            if marker not in source:
                continue
            raise UpdatePolicyError(
                "Direct source contains dormant update marker "
                f"{marker}: {source_path.name}"
            )

    return "Direct update policy verified: manual immutable releases only."


def main() -> int:
    info_plist = INFO_PLIST
    if len(sys.argv) == 3 and sys.argv[1] == "--info-plist":
        info_plist = Path(sys.argv[2]).resolve()
    elif len(sys.argv) != 1:
        print(
            "usage: verify-direct-update-policy.py "
            "[--info-plist /absolute/path/to/Info.plist]",
            file=sys.stderr,
        )
        return 64
    try:
        print(verify(info_plist=info_plist))
    except (OSError, plistlib.InvalidFileException, UpdatePolicyError) as error:
        print(f"Direct update policy verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
