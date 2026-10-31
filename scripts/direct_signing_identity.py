"""Reviewed public certificate pins; SHA-1 values are Apple CLI selectors only.

The certificates/private keys remain in the existing login Keychain. Adding a
new selector requires reviewing its public DER certificate and strong digest.
"""
from __future__ import annotations

import re

APPROVED_CERTIFICATE_SHA256 = {
    "474F7C78F33EE324C24F6F5AE0443EB713E85E60":
        "781a0b9f09d3c3ac3bd34017699882ae0bec2c1ecfbbce77077ead353f592728",
}


def certificate_sha256_for_selector(selector: str) -> str:
    if not isinstance(selector, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", selector):
        raise ValueError("Exact Apple signing identity selector required")
    digest = APPROVED_CERTIFICATE_SHA256.get(selector.upper())
    if digest is None or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Unreviewed signing certificate selector")
    return digest
