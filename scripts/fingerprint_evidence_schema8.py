#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import stat
import subprocess
import tempfile
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


MAXIMUM_PAYLOAD_BYTES = 4 * 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 1 * 1024 * 1024
MAXIMUM_ENROLLMENT_BINDING_BYTES = 4 * 1024
MAXIMUM_ENVELOPE_BYTES = ((MAXIMUM_PAYLOAD_BYTES + 2) // 3) * 4 + 4096
TRANSCRIPT_DOMAIN = b"NeAntik GUI fingerprint evidence v8\x00"
ALGORITHM = "P256-SHA256"
ENVELOPE_KIND = "neantik-gui-fingerprint-evidence"
PAYLOAD_ENCODING = "base64-json-utf8"
FIXED_OPENSSL_PATH = Path("/usr/bin/openssl")
ISO8601_UTC_SECONDS = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"
)
P256_ORDER = int(
    "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84"
    "F3B9CAC2FC632551",
    16,
)
P256_HALF_ORDER = P256_ORDER // 2
P256_FIELD_PRIME = int(
    "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF",
    16,
)
P256_CURVE_B = int(
    "5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B",
    16,
)
P256_SPKI_PREFIX = bytes.fromhex(
    "3059301306072a8648ce3d020106082a8648ce3d030107034200"
)
ENVELOPE_KEYS = {
    "schemaVersion",
    "kind",
    "payloadEncoding",
    "payload",
    "authentication",
}
AUTHENTICATION_KEYS = {
    "algorithm",
    "keyID",
    "candidateManifestSHA256",
    "sessionID",
    "challengeSHA256",
    "signatureDER",
}
BINDING_KEYS = {
    "schemaVersion",
    "algorithm",
    "authorityKeyID",
    "publicKeyX963",
    "sessionID",
    "challenge",
}


class FingerprintEvidenceVerificationError(ValueError):
    pass


@dataclass(frozen=True)
class VerifiedFingerprintEvidence:
    payload: bytes
    candidate_manifest_sha256: str
    payload_sha256: str
    challenge_sha256: str
    authority_key_id: str
    session_id: str
    transcript: bytes
    authenticated_evidence_id: str
    transport_sha256: str


def _reject_duplicate_pairs(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise FingerprintEvidenceVerificationError(
                "JSON contains a duplicate object key."
            )
        result[key] = value
    return result


def _reject_nonfinite_constant(value: str) -> Any:
    raise FingerprintEvidenceVerificationError(
        f"JSON contains a non-finite number: {value}."
    )


def canonical_json_bytes(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise FingerprintEvidenceVerificationError(
            "JSON cannot be represented canonically."
        ) from error


def load_canonical_json(
    raw: bytes,
    *,
    maximum_bytes: int,
    label: str,
) -> Any:
    if not raw or len(raw) > maximum_bytes:
        raise FingerprintEvidenceVerificationError(
            f"{label} has an invalid byte length."
        )
    try:
        text = raw.decode("utf-8", errors="strict")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite_constant,
        )
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        FingerprintEvidenceVerificationError,
    ) as error:
        if isinstance(error, FingerprintEvidenceVerificationError):
            raise
        raise FingerprintEvidenceVerificationError(
            f"{label} is not valid UTF-8 JSON."
        ) from error
    if not hmac.compare_digest(canonical_json_bytes(value), raw):
        raise FingerprintEvidenceVerificationError(
            f"{label} is not compact canonical JSON."
        )
    return value


def _require_exact_keys(
    value: Any,
    expected: set[str],
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise FingerprintEvidenceVerificationError(
            f"{label} has an invalid exact key set."
        )
    return value


def _require_exact_integer(value: Any, expected: int, label: str) -> None:
    if type(value) is not int or value != expected:
        raise FingerprintEvidenceVerificationError(
            f"{label} has an invalid value."
        )


def _require_exact_string(value: Any, expected: str, label: str) -> None:
    if not isinstance(value, str) or value != expected:
        raise FingerprintEvidenceVerificationError(
            f"{label} has an invalid value."
        )


def _canonical_base64(
    value: Any,
    *,
    expected_bytes: int | None,
    maximum_text_bytes: int,
    label: str,
) -> bytes:
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > maximum_text_bytes
        or not value.isascii()
    ):
        raise FingerprintEvidenceVerificationError(
            f"{label} is not bounded ASCII Base64."
        )
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise FingerprintEvidenceVerificationError(
            f"{label} is not valid Base64."
        ) from error
    if (
        base64.b64encode(decoded).decode("ascii") != value
        or (expected_bytes is not None and len(decoded) != expected_bytes)
    ):
        raise FingerprintEvidenceVerificationError(
            f"{label} is not canonical Base64."
        )
    return decoded


def _canonical_lower_hex(value: Any, *, bytes_count: int, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != bytes_count * 2
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise FingerprintEvidenceVerificationError(
            f"{label} is not canonical lowercase hexadecimal."
        )
    return value


def _canonical_wire_uuid(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise FingerprintEvidenceVerificationError(
            f"{label} is not a UUID string."
        )
    try:
        canonical = str(uuid.UUID(value))
    except (ValueError, AttributeError) as error:
        raise FingerprintEvidenceVerificationError(
            f"{label} is not a UUID string."
        ) from error
    if canonical.upper() != value:
        raise FingerprintEvidenceVerificationError(
            f"{label} is not a canonical uppercase UUID."
        )
    return value


def read_bounded_regular_file(
    path: Path,
    *,
    maximum_bytes: int,
    label: str,
) -> bytes:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor: int | None = None
    try:
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_size < 1
            or metadata.st_size > maximum_bytes
        ):
            raise FingerprintEvidenceVerificationError(
                f"{label} is not a bounded regular file."
            )
        chunks: list[bytes] = []
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1024))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        extra = os.read(descriptor, 1)
        raw = b"".join(chunks)
        final_metadata = os.fstat(descriptor)
        if (
            remaining
            or extra
            or len(raw) != metadata.st_size
            or final_metadata.st_dev != metadata.st_dev
            or final_metadata.st_ino != metadata.st_ino
            or final_metadata.st_nlink != metadata.st_nlink
            or final_metadata.st_size != metadata.st_size
            or final_metadata.st_mtime_ns != metadata.st_mtime_ns
            or final_metadata.st_ctime_ns != metadata.st_ctime_ns
        ):
            raise FingerprintEvidenceVerificationError(
                f"{label} changed while it was being read."
            )
        return raw
    except FingerprintEvidenceVerificationError:
        raise
    except OSError as error:
        raise FingerprintEvidenceVerificationError(
            f"{label} could not be read safely."
        ) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def validate_p256_public_key_x963(public_key_x963: bytes) -> bytes:
    if len(public_key_x963) != 65 or public_key_x963[0] != 0x04:
        raise FingerprintEvidenceVerificationError(
            "Manifest P-256 public key is not an uncompressed X9.63 point."
        )
    x = int.from_bytes(public_key_x963[1:33], "big")
    y = int.from_bytes(public_key_x963[33:65], "big")
    if (
        x >= P256_FIELD_PRIME
        or y >= P256_FIELD_PRIME
        or (
            (y * y)
            - (
                (x * x * x)
                - (3 * x)
                + P256_CURVE_B
            )
        )
        % P256_FIELD_PRIME
        != 0
    ):
        raise FingerprintEvidenceVerificationError(
            "Manifest P-256 public key is not on the P-256 curve."
        )
    return public_key_x963


def validate_manifest_binding(value: Any) -> dict[str, Any]:
    binding = _require_exact_keys(
        value,
        BINDING_KEYS,
        "Fingerprint binding",
    )
    _require_exact_integer(
        binding.get("schemaVersion"),
        1,
        "Fingerprint binding schemaVersion",
    )
    _require_exact_string(
        binding.get("algorithm"),
        ALGORITHM,
        "Fingerprint binding algorithm",
    )
    public_key_x963 = validate_p256_public_key_x963(
        _canonical_base64(
            binding.get("publicKeyX963"),
            expected_bytes=65,
            maximum_text_bytes=128,
            label="Manifest public key",
        )
    )
    authority_key_id = _canonical_lower_hex(
        binding.get("authorityKeyID"),
        bytes_count=32,
        label="Manifest authority key ID",
    )
    expected_key_id = hashlib.sha256(public_key_x963).hexdigest()
    if not hmac.compare_digest(authority_key_id, expected_key_id):
        raise FingerprintEvidenceVerificationError(
            "Manifest authority key ID does not match its public key."
        )
    _canonical_wire_uuid(
        binding.get("sessionID"),
        "Manifest sessionID",
    )
    _canonical_base64(
        binding.get("challenge"),
        expected_bytes=32,
        maximum_text_bytes=64,
        label="Manifest challenge",
    )
    return dict(binding)


def load_enrollment_binding(path: Path) -> dict[str, Any]:
    raw = read_bounded_regular_file(
        path,
        maximum_bytes=MAXIMUM_ENROLLMENT_BINDING_BYTES,
        label="Fingerprint enrollment binding",
    )
    return validate_manifest_binding(
        load_canonical_json(
            raw,
            maximum_bytes=MAXIMUM_ENROLLMENT_BINDING_BYTES,
            label="Fingerprint enrollment binding",
        )
    )


def _validate_iso8601_date(value: Any, label: str) -> None:
    if (
        not isinstance(value, str)
        or ISO8601_UTC_SECONDS.fullmatch(value) is None
    ):
        raise FingerprintEvidenceVerificationError(
            f"{label} is not an ISO-8601 UTC timestamp."
        )
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise FingerprintEvidenceVerificationError(
            f"{label} is not an ISO-8601 UTC timestamp."
        ) from error


def _validate_capture(value: Any, label: str) -> None:
    capture = _require_exact_keys(
        value,
        {
            "profileID",
            "profileName",
            "identityCode",
            "capturedAt",
            "values",
        },
        label,
    )
    _canonical_wire_uuid(capture.get("profileID"), f"{label} profileID")
    for key in ("profileName", "identityCode"):
        if not isinstance(capture.get(key), str):
            raise FingerprintEvidenceVerificationError(
                f"{label} {key} is not a string."
            )
    _validate_iso8601_date(capture.get("capturedAt"), f"{label} capturedAt")
    values = capture.get("values")
    if (
        not isinstance(values, dict)
        or not all(
            isinstance(key, str) and isinstance(item, str)
            for key, item in values.items()
        )
    ):
        raise FingerprintEvidenceVerificationError(
            f"{label} values are not a string dictionary."
        )


def _validate_optional_type(
    report: dict[str, Any],
    key: str,
    expected_type: type,
) -> None:
    value = report.get(key)
    if key in report and value is not None and type(value) is not expected_type:
        raise FingerprintEvidenceVerificationError(
            f"Fingerprint evidence payload {key} has an invalid type."
        )


def _validate_schema7_payload(value: Any) -> None:
    if not isinstance(value, dict):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload is not a schema-7 object."
        )
    allowed_keys = {
        "id",
        "createdAt",
        "auditSchemaVersion",
        "identityCatalogVersion",
        "managerVersion",
        "managerBuild",
        "runtimeName",
        "runtimeVersion",
        "runtimeFlavor",
        "runtimeCodeSignatureValid",
        "runtimeExecutableSHA256",
        "runtimeFrameworkSHA256",
        "executionMode",
        "webrtcDirectControl",
        "firstInitial",
        "second",
        "firstRepeat",
    }
    required_keys = {
        "id",
        "createdAt",
        "auditSchemaVersion",
        "runtimeName",
        "runtimeFlavor",
        "firstInitial",
        "second",
        "firstRepeat",
    }
    if not required_keys.issubset(value) or not set(value).issubset(
        allowed_keys
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload has an invalid schema-7 key set."
        )
    _require_exact_integer(
        value.get("auditSchemaVersion"),
        7,
        "Fingerprint evidence payload auditSchemaVersion",
    )
    _canonical_wire_uuid(value.get("id"), "Fingerprint evidence payload id")
    _validate_iso8601_date(
        value.get("createdAt"),
        "Fingerprint evidence payload createdAt",
    )
    if (
        not isinstance(value.get("runtimeName"), str)
        or value.get("runtimeFlavor")
        not in {"standard", "fingerprintChromium", "cloak"}
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload runtime metadata is invalid."
        )
    _validate_optional_type(value, "identityCatalogVersion", int)
    for key in (
        "managerVersion",
        "managerBuild",
        "runtimeVersion",
        "runtimeExecutableSHA256",
        "runtimeFrameworkSHA256",
    ):
        _validate_optional_type(value, key, str)
    _validate_optional_type(value, "runtimeCodeSignatureValid", bool)
    if (
        value.get("executionMode") is not None
        and value.get("executionMode")
        not in {"browser", "headless-single-process-diagnostic"}
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload executionMode is invalid."
        )
    for key in ("firstInitial", "second", "firstRepeat"):
        _validate_capture(value.get(key), f"Fingerprint evidence payload {key}")
    if value.get("webrtcDirectControl") is not None:
        _validate_capture(
            value.get("webrtcDirectControl"),
            "Fingerprint evidence payload webrtcDirectControl",
        )


def parse_strict_p256_der(signature: bytes) -> tuple[int, int]:
    if not 8 <= len(signature) <= 72:
        raise FingerprintEvidenceVerificationError(
            "ECDSA signature has an invalid DER length."
        )
    if signature[0] != 0x30 or signature[1] != len(signature) - 2:
        raise FingerprintEvidenceVerificationError(
            "ECDSA signature is not a canonical DER sequence."
        )
    offset = 2
    scalars: list[int] = []
    for _ in range(2):
        if offset + 2 > len(signature) or signature[offset] != 0x02:
            raise FingerprintEvidenceVerificationError(
                "ECDSA signature is missing a DER integer."
            )
        length = signature[offset + 1]
        offset += 2
        if length < 1 or length > 33 or offset + length > len(signature):
            raise FingerprintEvidenceVerificationError(
                "ECDSA signature has an invalid integer length."
            )
        encoded = signature[offset : offset + length]
        offset += length
        if encoded[0] & 0x80:
            raise FingerprintEvidenceVerificationError(
                "ECDSA signature contains a negative integer."
            )
        if (
            len(encoded) > 1
            and encoded[0] == 0
            and encoded[1] < 0x80
        ):
            raise FingerprintEvidenceVerificationError(
                "ECDSA signature contains a redundant leading zero."
            )
        scalar = int.from_bytes(encoded, "big")
        if not 0 < scalar < P256_ORDER:
            raise FingerprintEvidenceVerificationError(
                "ECDSA signature scalar is outside the P-256 range."
            )
        scalars.append(scalar)
    if offset != len(signature):
        raise FingerprintEvidenceVerificationError(
            "ECDSA signature contains trailing DER bytes."
        )
    if scalars[1] > P256_HALF_ORDER:
        raise FingerprintEvidenceVerificationError(
            "ECDSA signature is not normalized to low-S."
        )
    return scalars[0], scalars[1]


def _public_key_pem(public_key_x963: bytes) -> bytes:
    validate_p256_public_key_x963(public_key_x963)
    spki = P256_SPKI_PREFIX + public_key_x963
    encoded = base64.b64encode(spki).decode("ascii")
    lines = [encoded[index : index + 64] for index in range(0, len(encoded), 64)]
    return (
        "-----BEGIN PUBLIC KEY-----\n"
        + "\n".join(lines)
        + "\n-----END PUBLIC KEY-----\n"
    ).encode("ascii")


def _verify_with_openssl(
    *,
    public_key_x963: bytes,
    signature_der: bytes,
    transcript: bytes,
    timeout_seconds: float,
) -> None:
    if not FIXED_OPENSSL_PATH.is_file():
        raise FingerprintEvidenceVerificationError(
            "The fixed OpenSSL verifier is unavailable."
        )
    try:
        with tempfile.TemporaryDirectory(
            prefix="neantik-fingerprint-evidence-"
        ) as directory:
            root = Path(directory)
            public_key = root / "public-key.pem"
            signature = root / "signature.der"
            public_key.write_bytes(_public_key_pem(public_key_x963))
            signature.write_bytes(signature_der)
            completed = subprocess.run(
                [
                    str(FIXED_OPENSSL_PATH),
                    "dgst",
                    "-sha256",
                    "-verify",
                    str(public_key),
                    "-signature",
                    str(signature),
                ],
                input=transcript,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout_seconds,
                check=False,
                env={
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                },
            )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise FingerprintEvidenceVerificationError(
            "OpenSSL could not complete fingerprint evidence verification."
        ) from error
    if completed.returncode != 0:
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence signature is invalid."
        )


def verify_fingerprint_evidence(
    *,
    candidate_manifest_raw: bytes,
    envelope_raw: bytes,
    timeout_seconds: float = 10,
) -> VerifiedFingerprintEvidence:
    manifest = load_canonical_json(
        candidate_manifest_raw,
        maximum_bytes=MAXIMUM_MANIFEST_BYTES,
        label="Candidate manifest",
    )
    if not isinstance(manifest, dict):
        raise FingerprintEvidenceVerificationError(
            "Candidate manifest must be a JSON object."
        )
    _require_exact_integer(
        manifest.get("schemaVersion"),
        3,
        "Candidate manifest schemaVersion",
    )
    binding = validate_manifest_binding(
        manifest.get("fingerprintEvidence")
    )
    public_key_x963 = base64.b64decode(
        binding["publicKeyX963"],
        validate=True,
    )
    authority_key_id = str(binding["authorityKeyID"])
    session_id = _canonical_wire_uuid(
        binding.get("sessionID"),
        "Manifest sessionID",
    )
    challenge = _canonical_base64(
        binding.get("challenge"),
        expected_bytes=32,
        maximum_text_bytes=64,
        label="Manifest challenge",
    )

    envelope = _require_exact_keys(
        load_canonical_json(
            envelope_raw,
            maximum_bytes=MAXIMUM_ENVELOPE_BYTES,
            label="Fingerprint evidence envelope",
        ),
        ENVELOPE_KEYS,
        "Fingerprint evidence envelope",
    )
    _require_exact_integer(
        envelope.get("schemaVersion"),
        8,
        "Fingerprint evidence schemaVersion",
    )
    _require_exact_string(
        envelope.get("kind"),
        ENVELOPE_KIND,
        "Fingerprint evidence kind",
    )
    _require_exact_string(
        envelope.get("payloadEncoding"),
        PAYLOAD_ENCODING,
        "Fingerprint evidence payload encoding",
    )
    payload = _canonical_base64(
        envelope.get("payload"),
        expected_bytes=None,
        maximum_text_bytes=((MAXIMUM_PAYLOAD_BYTES + 2) // 3) * 4,
        label="Fingerprint evidence payload",
    )
    if len(payload) > MAXIMUM_PAYLOAD_BYTES:
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload is too large."
        )
    authentication = _require_exact_keys(
        envelope.get("authentication"),
        AUTHENTICATION_KEYS,
        "Fingerprint evidence authentication",
    )
    _require_exact_string(
        authentication.get("algorithm"),
        ALGORITHM,
        "Fingerprint evidence authentication algorithm",
    )
    authentication_key_id = _canonical_lower_hex(
        authentication.get("keyID"),
        bytes_count=32,
        label="Fingerprint evidence key ID",
    )
    manifest_sha256 = hashlib.sha256(candidate_manifest_raw).hexdigest()
    recorded_manifest_sha256 = _canonical_lower_hex(
        authentication.get("candidateManifestSHA256"),
        bytes_count=32,
        label="Fingerprint evidence candidate manifest SHA-256",
    )
    authentication_session_id = _canonical_wire_uuid(
        authentication.get("sessionID"),
        "Fingerprint evidence sessionID",
    )
    challenge_sha256 = hashlib.sha256(challenge).hexdigest()
    recorded_challenge_sha256 = _canonical_lower_hex(
        authentication.get("challengeSHA256"),
        bytes_count=32,
        label="Fingerprint evidence challenge SHA-256",
    )
    if not (
        hmac.compare_digest(authentication_key_id, authority_key_id)
        and hmac.compare_digest(
            recorded_manifest_sha256,
            manifest_sha256,
        )
        and authentication_session_id == session_id
        and hmac.compare_digest(
            recorded_challenge_sha256,
            challenge_sha256,
        )
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence does not match the candidate binding."
        )
    signature_der = _canonical_base64(
        authentication.get("signatureDER"),
        expected_bytes=None,
        maximum_text_bytes=128,
        label="Fingerprint evidence signature",
    )
    parse_strict_p256_der(signature_der)

    payload_value = load_canonical_json(
        payload,
        maximum_bytes=MAXIMUM_PAYLOAD_BYTES,
        label="Fingerprint evidence payload",
    )
    _validate_schema7_payload(payload_value)
    payload_sha256 = hashlib.sha256(payload).hexdigest()
    transcript = (
        TRANSCRIPT_DOMAIN
        + bytes.fromhex(manifest_sha256)
        + session_id.lower().encode("ascii")
        + challenge
        + bytes.fromhex(payload_sha256)
    )
    _verify_with_openssl(
        public_key_x963=public_key_x963,
        signature_der=signature_der,
        transcript=transcript,
        timeout_seconds=timeout_seconds,
    )
    return VerifiedFingerprintEvidence(
        payload=payload,
        candidate_manifest_sha256=manifest_sha256,
        payload_sha256=payload_sha256,
        challenge_sha256=challenge_sha256,
        authority_key_id=authority_key_id,
        session_id=session_id,
        transcript=transcript,
        authenticated_evidence_id=hashlib.sha256(transcript).hexdigest(),
        transport_sha256=hashlib.sha256(envelope_raw).hexdigest(),
    )
