#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import binascii
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


PROJECT_ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = PROJECT_ROOT / "Resources" / "Info.plist"
SWIFT_SOURCE = PROJECT_ROOT / "Sources" / "NeAntik" / "UpdateManifest.swift"


class UpdatePolicyError(ValueError):
    pass


def validate_https_manifest_url(value: str) -> None:
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower()
    if (
        parsed.scheme != "https"
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path.endswith(".json")
        or host == "localhost"
        or host == "::1"
        or host.startswith("127.")
        or host.endswith((".local", ".test", ".invalid", ".example"))
    ):
        raise UpdatePolicyError(
            "enabled update manifest URL must be credential-free HTTPS JSON"
        )


def validate_public_key(key_id: str, encoded: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", key_id):
        raise UpdatePolicyError("enabled update public key ID is invalid")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise UpdatePolicyError(
            "enabled update public key is not valid Base64"
        ) from error
    if len(decoded) != 32:
        raise UpdatePolicyError(
            "enabled Ed25519 update public key must contain exactly 32 bytes"
        )


def verify(
    *,
    info_plist: Path = INFO_PLIST,
    swift_source: Path = SWIFT_SOURCE,
) -> str:
    with info_plist.open("rb") as handle:
        info = plistlib.load(handle)
    source = swift_source.read_text(encoding="utf-8")

    enabled = info.get("NeAntikUpdateChannelEnabled")
    automatic_download = info.get("NeAntikUpdateAutoDownload")
    manifest_url = info.get("NeAntikUpdateManifestURL")
    key_id = info.get("NeAntikUpdatePublicKeyID")
    public_key = info.get("NeAntikUpdatePublicKeyBase64")

    if not isinstance(enabled, bool):
        raise UpdatePolicyError("NeAntikUpdateChannelEnabled must be Boolean")
    if automatic_download is not False:
        raise UpdatePolicyError(
            "Direct automatic update download must remain explicitly disabled"
        )
    for name, value in (
        ("NeAntikUpdateManifestURL", manifest_url),
        ("NeAntikUpdatePublicKeyID", key_id),
        ("NeAntikUpdatePublicKeyBase64", public_key),
    ):
        if not isinstance(value, str):
            raise UpdatePolicyError(f"{name} must be a string")

    if enabled:
        validate_https_manifest_url(manifest_url)
        validate_public_key(key_id, public_key)
        status = "configured"
    else:
        if manifest_url or key_id or public_key:
            raise UpdatePolicyError(
                "disabled update channel must not retain partial trust material"
            )
        status = "disabled-manual"

    required_contracts = (
        'envelope.algorithm == "Ed25519"',
        "publicKey.isValidSignature",
        'payload.architecture == "arm64"',
        'payload.artifactKind == "public-notarized"',
        'payload.publicReleaseState == "public-ready"',
        "maximumLifetime",
        "components.scheme == \"https\"",
    )
    missing = [item for item in required_contracts if item not in source]
    if missing:
        raise UpdatePolicyError(
            "Swift update verifier is missing fail-closed contracts: "
            + ", ".join(missing)
        )

    forbidden_network_implementation = (
        "URLSession",
        "downloadTask(",
        "download(from:",
        "Process()",
    )
    present = [
        item for item in forbidden_network_implementation if item in source
    ]
    if present:
        raise UpdatePolicyError(
            "update verifier must remain offline until updater review: "
            + ", ".join(present)
        )

    return (
        "Direct signed-update policy verified: "
        f"{status}; Ed25519 offline verifier; automatic download disabled."
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the fail-closed NeAntik Direct update policy."
    )
    parser.add_argument("--info-plist", type=Path, default=INFO_PLIST)
    parser.add_argument("--swift-source", type=Path, default=SWIFT_SOURCE)
    args = parser.parse_args()
    try:
        print(
            verify(
                info_plist=args.info_plist.resolve(),
                swift_source=args.swift_source.resolve(),
            )
        )
    except (OSError, plistlib.InvalidFileException, UpdatePolicyError) as error:
        print(f"Direct update policy verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
