#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = (
    ROOT
    / "scripts"
    / "tests"
    / "fixtures"
    / "fingerprint-evidence-schema8-swift.json"
)
OPENSSL = Path("/usr/bin/openssl")
P256_ORDER = int(
    "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84"
    "F3B9CAC2FC632551",
    16,
)
PRIVATE_SCALAR_ONE_DER = bytes.fromhex(
    "30770201010420"
    + ("00" * 31)
    + "01"
    + "a00a06082a8648ce3d030107"
    + "a14403420004"
    + "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
    + "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
)
PUBLIC_KEY_X963 = bytes.fromhex(
    "04"
    "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
    "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
)


def canonical(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def pem(label: str, data: bytes) -> bytes:
    encoded = base64.b64encode(data).decode("ascii")
    lines = [
        encoded[index : index + 64]
        for index in range(0, len(encoded), 64)
    ]
    return (
        f"-----BEGIN {label}-----\n"
        + "\n".join(lines)
        + f"\n-----END {label}-----\n"
    ).encode("ascii")


def parse_der(signature: bytes) -> tuple[int, int]:
    if len(signature) < 8 or signature[0] != 0x30:
        raise ValueError("invalid DER")
    index = 2
    values: list[int] = []
    for _ in range(2):
        if signature[index] != 0x02:
            raise ValueError("invalid DER")
        length = signature[index + 1]
        start = index + 2
        values.append(int.from_bytes(signature[start : start + length], "big"))
        index = start + length
    if index != len(signature):
        raise ValueError("invalid DER")
    return values[0], values[1]


def der_integer(value: int) -> bytes:
    encoded = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if encoded[0] & 0x80:
        encoded = b"\x00" + encoded
    return b"\x02" + bytes([len(encoded)]) + encoded


def low_s(signature: bytes) -> bytes:
    r, s = parse_der(signature)
    if s > P256_ORDER // 2:
        s = P256_ORDER - s
    body = der_integer(r) + der_integer(s)
    return b"\x30" + bytes([len(body)]) + body


def sign(transcript: bytes, private_key: Path) -> bytes:
    completed = subprocess.run(
        [
            str(OPENSSL),
            "dgst",
            "-sha256",
            "-sign",
            str(private_key),
        ],
        input=transcript,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        env={
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
        },
    )
    return low_s(completed.stdout)


def main() -> int:
    challenge = bytes(range(32))
    authority_key_id = hashlib.sha256(PUBLIC_KEY_X963).hexdigest()
    binding = {
        "schemaVersion": 1,
        "algorithm": "P256-SHA256",
        "authorityKeyID": authority_key_id,
        "publicKeyX963": base64.b64encode(PUBLIC_KEY_X963).decode("ascii"),
        "sessionID": "11111111-2222-3333-4444-555555555555",
        "challenge": base64.b64encode(challenge).decode("ascii"),
    }
    manifest = canonical(
        {
            "schemaVersion": 3,
            "kind": "neantik-direct-prepared-candidate",
            "releaseChannel": "public-alpha",
            "preparedAt": "1970-01-01T00:00:00Z",
            "bundle": {
                "name": "NeAntik.app",
                "identifier": "app.neantik.desktop",
                "version": "0.3.12",
                "build": "15",
            },
            "criticalFiles": {
                "managerInfoPlist": {
                    "bundlePath": "Contents/Info.plist",
                    "sha256": "d" * 64,
                },
                "managerExecutable": {
                    "bundlePath": "Contents/MacOS/NeAntik",
                    "sha256": "c" * 64,
                },
                "runtimeInfoPlist": {
                    "bundlePath": (
                        "Contents/Resources/NeAntik Browser.app/"
                        "Contents/Info.plist"
                    ),
                    "sha256": "e" * 64,
                },
                "runtimeExecutable": {
                    "bundlePath": (
                        "Contents/Resources/NeAntik Browser.app/"
                        "Contents/MacOS/NeAntik Browser"
                    ),
                    "sha256": "a" * 64,
                },
                "runtimeFramework": {
                    "bundlePath": (
                        "Contents/Resources/NeAntik Browser.app/Contents/"
                        "Frameworks/NeVision Browser Framework.framework/"
                        "Versions/150.0.7871.186/"
                        "NeVision Browser Framework"
                    ),
                    "sha256": "b" * 64,
                },
                "runtimeVerification": {
                    "bundlePath": (
                        "Contents/Resources/NeAntikRuntimeEvidence/"
                        "runtime-verification.json"
                    ),
                    "sha256": "f" * 64,
                },
                "runtimeCandidateLock": {
                    "bundlePath": (
                        "Contents/Resources/NeAntikRuntimeEvidence/"
                        "fingerprint-chromium.lock.json"
                    ),
                    "sha256": "1" * 64,
                },
                "sourceContract": {
                    "bundlePath": (
                        "Contents/Resources/NeAntikRuntimeEvidence/"
                        "chromium-150-source-contract.json"
                    ),
                    "sha256": "2" * 64,
                },
                "sourceProvenance": {
                    "bundlePath": (
                        "Contents/Resources/NeAntikRuntimeEvidence/"
                        "source-provenance.json"
                    ),
                    "sha256": "3" * 64,
                },
                "buildArguments": {
                    "bundlePath": (
                        "Contents/Resources/NeAntikRuntimeEvidence/args.gn"
                    ),
                    "sha256": "4" * 64,
                },
            },
            "bundleInventory": [],
            "postPreparationMutablePaths": ["Contents/CodeResources"],
            "fingerprintEvidence": binding,
            "boundary": "test candidate boundary",
        }
    )
    payload = canonical(
        {
            "schemaVersion": 1,
            "kind": "neantik-fingerprint-release-result",
            "createdAt": "1970-01-01T00:00:03Z",
            "releaseChannel": "public-alpha",
            "managerVersion": "0.3.12",
            "managerBuild": "15",
            "runtimeName": "NeAntik Browser",
            "runtimeVersion": "150.0.7871.186",
            "runtimeFlavor": "fingerprintChromium",
            "runtimeCodeSignatureValid": True,
            "runtimeExecutableSHA256": "a" * 64,
            "runtimeFrameworkSHA256": "b" * 64,
            "auditSchemaVersion": 7,
            "identityCatalogVersion": 1,
            "executionMode": "browser",
            "verdict": "verified",
            "criticalSurfaces": {
                "canvas": "stable-different",
                "webgl_pixels": "stable-different",
                "audio": "stable-same",
                "client_rects": "stable-same",
            },
            "changedCriticalKeys": ["canvas", "webgl_pixels"],
            "unavailableRequiredKeys": ["worker_canvas"],
            "unstableRequiredKeys": [],
            "profileSequenceValid": True,
            "identitySequenceValid": True,
            "crossRealmConsistent": False,
            "deviceTupleConsistent": False,
            "networkPrivacyControlled": False,
            "publicAlphaQualified": True,
            "productionQualified": False,
            "limitations": ["strict-coherence-not-qualified"],
        }
    )
    manifest_sha = hashlib.sha256(manifest).digest()
    payload_sha = hashlib.sha256(payload).digest()
    transcript = (
        b"NeAntik GUI fingerprint evidence v8\x00"
        + manifest_sha
        + binding["sessionID"].lower().encode("ascii")
        + challenge
        + payload_sha
    )
    with tempfile.TemporaryDirectory(
        prefix="neantik-schema8-fixture-"
    ) as temporary:
        private_key = Path(temporary) / "private-key.pem"
        private_key.write_bytes(
            pem("EC PRIVATE KEY", PRIVATE_SCALAR_ONE_DER)
        )
        signature = sign(transcript, private_key)
        second_signature = sign(transcript, private_key)
    authentication = {
        "algorithm": "P256-SHA256",
        "keyID": authority_key_id,
        "candidateManifestSHA256": manifest_sha.hex(),
        "sessionID": binding["sessionID"],
        "challengeSHA256": hashlib.sha256(challenge).hexdigest(),
        "signatureDER": base64.b64encode(signature).decode("ascii"),
    }
    envelope = canonical(
        {
            "schemaVersion": 8,
            "kind": "neantik-gui-fingerprint-evidence",
            "payloadEncoding": "base64-json-utf8",
            "payload": base64.b64encode(payload).decode("ascii"),
            "authentication": authentication,
        }
    )
    second_envelope_value = json.loads(envelope)
    second_envelope_value["authentication"]["signatureDER"] = (
        base64.b64encode(second_signature).decode("ascii")
    )
    second_envelope = canonical(second_envelope_value)
    fixture = {
        "kind": "neantik-schema8-cross-language-test-fixture",
        "keyNote": (
            "Known test scalar 1; DEBUG-only and forbidden for production "
            "enrollment."
        ),
        "opensslSignatureBase64": base64.b64encode(
            second_signature
        ).decode("ascii"),
        "opensslTransportSHA256": hashlib.sha256(
            second_envelope
        ).hexdigest(),
        "expected": {
            "authenticatedEvidenceID": hashlib.sha256(
                transcript
            ).hexdigest(),
            "authorityKeyID": authority_key_id,
            "candidateManifestSHA256": manifest_sha.hex(),
            "challengeSHA256": hashlib.sha256(challenge).hexdigest(),
            "payloadSHA256": payload_sha.hex(),
            "transcriptBase64": base64.b64encode(
                transcript
            ).decode("ascii"),
            "transportSHA256": hashlib.sha256(envelope).hexdigest(),
        },
        "manifestBase64": base64.b64encode(manifest).decode("ascii"),
        "envelopeBase64": base64.b64encode(envelope).decode("ascii"),
        "payloadBase64": base64.b64encode(payload).decode("ascii"),
    }
    OUTPUT.write_text(
        json.dumps(
            fixture,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
