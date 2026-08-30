#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = (
    PROJECT_ROOT
    / "Sources"
    / "NeAntik"
    / "SecureEnclaveFingerprintEvidenceSigner.swift"
)


class SecureEnclaveAuthorityError(ValueError):
    pass


def verify(source_path: Path = DEFAULT_SOURCE) -> str:
    source = source_path.read_text(encoding="utf-8")
    required = (
        "kSecAttrTokenIDSecureEnclave",
        "SecKeyCreateRandomKey",
        "SecKeyCopyAttributes",
        "validateSecureEnclaveKey(privateKey)",
    )
    missing = [token for token in required if token not in source]
    if missing:
        raise SecureEnclaveAuthorityError(
            "production authority is missing hardware-key checks: "
            + ", ".join(missing)
        )

    forbidden = (
        "fallbackKeyService",
        "createFallbackPrivateKey",
        "fallbackPrivateKey",
        "P256.Signing.PrivateKey",
        "rawRepresentation",
        "errSecMissingEntitlement",
    )
    present = [token for token in forbidden if token in source]
    if present:
        raise SecureEnclaveAuthorityError(
            "production authority contains a software-key fallback: "
            + ", ".join(present)
        )

    return (
        "Secure Enclave release authority verified: hardware-backed, "
        "attribute-checked and fail-closed."
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the Direct release evidence authority."
    )
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    args = parser.parse_args()
    try:
        print(verify(args.source.resolve()))
    except (OSError, SecureEnclaveAuthorityError) as error:
        print(
            f"Secure Enclave release authority verification failed: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
