#!/usr/bin/env python3
"""Version 9 semantic evidence; historical schema 8 is deliberately unchanged.

Only bounded canonical wire parsing and P256 verification primitives are reused.
No failed-v9-to-v8 fallback is permitted.
"""
from __future__ import annotations
import base64
import hashlib
import hmac
import re
from pathlib import Path
from typing import Any
import fingerprint_evidence_schema8 as legacy
from fingerprint_evidence_schema8 import (
    FingerprintEvidenceVerificationError, VerifiedFingerprintEvidence,
    MAXIMUM_PAYLOAD_BYTES, MAXIMUM_MANIFEST_BYTES, MAXIMUM_ENVELOPE_BYTES,
    MAXIMUM_ENROLLMENT_BINDING_BYTES, ENVELOPE_KEYS, AUTHENTICATION_KEYS,
    MANIFEST_KEYS, CRITICAL_FILE_KEYS, CRITICAL_SURFACE_KEYS, CRITICAL_SURFACE_STATES,
    ALGORITHM, ENVELOPE_KIND, PAYLOAD_ENCODING,
    canonical_json_bytes, load_canonical_json, read_bounded_regular_file,
    validate_p256_public_key_x963, parse_strict_p256_der,
    _require_exact_keys, _require_exact_integer, _require_exact_string,
    _canonical_base64, _canonical_lower_hex, _canonical_wire_uuid,
    _validate_iso8601_date, _is_lower_sha256, _require_sorted_unique_string_list,
    _validate_hashed_entry, _verify_with_openssl,
)
SEMANTIC_POLICY_ID = "repeatable-critical-observations-v1"
TRANSCRIPT_DOMAIN = b"NeAntik GUI fingerprint evidence v9\x00"
BINDING_KEYS = legacy.BINDING_KEYS | {"evidenceSchemaVersion", "auditSchemaVersion",
                                       "payloadSchemaVersion", "semanticPolicyID"}
RELEASE_PAYLOAD_KEYS = legacy.RELEASE_PAYLOAD_KEYS | {"semanticPolicyID", "criticalObservationsStable"}
EXACT_CRITICAL_FILE_PATHS = dict(legacy.EXACT_CRITICAL_FILE_PATHS)
EXACT_CRITICAL_FILE_PATHS["sourceContract"] += (
    "Contents/Resources/NeAntikRuntimeEvidence/chromium-15612-source-contract.json",
)

def validate_manifest_binding(value: Any) -> dict[str, Any]:
    binding = _require_exact_keys(
        value,
        BINDING_KEYS,
        "Fingerprint binding",
    )
    _require_exact_integer(
        binding.get("schemaVersion"),
        2,
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
    for key, expected in (("evidenceSchemaVersion", 9), ("auditSchemaVersion", 8),
                          ("payloadSchemaVersion", 2)):
        _require_exact_integer(binding.get(key), expected, "Fingerprint binding " + key)
    _require_exact_string(binding.get("semanticPolicyID"), SEMANTIC_POLICY_ID,
                          "Fingerprint binding semantic policy")
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

def _validate_release_payload(value: Any) -> dict[str, Any]:
    payload = _require_exact_keys(
        value,
        RELEASE_PAYLOAD_KEYS,
        "Fingerprint evidence release payload",
    )
    _require_exact_integer(
        payload.get("schemaVersion"),
        2,
        "Fingerprint evidence payload schemaVersion",
    )
    _require_exact_string(
        payload.get("kind"),
        "neantik-fingerprint-release-result",
        "Fingerprint evidence payload kind",
    )
    _validate_iso8601_date(
        payload.get("createdAt"),
        "Fingerprint evidence payload createdAt",
    )
    channel = payload.get("releaseChannel")
    if channel not in {"public-alpha", "production"}:
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload releaseChannel is invalid."
        )
    for key in (
        "managerVersion",
        "managerBuild",
        "runtimeName",
        "runtimeVersion",
    ):
        if not isinstance(payload.get(key), str) or not payload[key]:
            raise FingerprintEvidenceVerificationError(
                f"Fingerprint evidence payload {key} is invalid."
            )
    if payload.get("runtimeFlavor") not in {
        "standard",
        "fingerprintChromium",
        "cloak",
    }:
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload runtimeFlavor is invalid."
        )
    if payload.get("runtimeCodeSignatureValid") is not True:
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload runtime signature is invalid."
        )
    for key in (
        "runtimeExecutableSHA256",
        "runtimeFrameworkSHA256",
    ):
        if not _is_lower_sha256(payload.get(key)):
            raise FingerprintEvidenceVerificationError(
                f"Fingerprint evidence payload {key} is invalid."
            )
    _require_exact_integer(
        payload.get("auditSchemaVersion"),
        8,
        "Fingerprint evidence payload auditSchemaVersion",
    )
    _require_exact_integer(
        payload.get("identityCatalogVersion"),
        1,
        "Fingerprint evidence payload identityCatalogVersion",
    )
    _require_exact_string(
        payload.get("executionMode"),
        "browser",
        "Fingerprint evidence payload executionMode",
    )
    _require_exact_string(payload.get("semanticPolicyID"), SEMANTIC_POLICY_ID,
                          "Fingerprint evidence semantic policy")
    if payload.get("criticalObservationsStable") is not True:
        raise FingerprintEvidenceVerificationError("Critical observations are not stable.")
    surfaces = _require_exact_keys(
        payload.get("criticalSurfaces"),
        CRITICAL_SURFACE_KEYS,
        "Fingerprint evidence payload criticalSurfaces",
    )
    if (
        any(value not in {"stable-same", "stable-different"} for value in surfaces.values())
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload critical surfaces are invalid."
        )
    changed = _require_sorted_unique_string_list(
        payload.get("changedCriticalKeys"),
        "Fingerprint evidence payload changedCriticalKeys",
    )
    if (
        not set(changed).issubset(CRITICAL_SURFACE_KEYS)
        or changed
        != sorted(
            key
            for key, value in surfaces.items()
            if value == "stable-different"
        )
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload changedCriticalKeys are invalid."
        )
    expected_verdict = "verified" if len(changed) >= 2 else "partial" if changed else "unchanged"
    _require_exact_string(payload.get("verdict"), expected_verdict,
                          "Fingerprint evidence difference verdict")
    unavailable = _require_sorted_unique_string_list(
        payload.get("unavailableRequiredKeys"),
        "Fingerprint evidence payload unavailableRequiredKeys",
    )
    unstable = _require_sorted_unique_string_list(
        payload.get("unstableRequiredKeys"),
        "Fingerprint evidence payload unstableRequiredKeys",
    )
    limitations = _require_sorted_unique_string_list(
        payload.get("limitations"),
        "Fingerprint evidence payload limitations",
    )
    for key in (
        "profileSequenceValid",
        "identitySequenceValid",
        "crossRealmConsistent",
        "deviceTupleConsistent",
        "networkPrivacyControlled",
        "publicAlphaQualified",
        "productionQualified",
    ):
        if type(payload.get(key)) is not bool:
            raise FingerprintEvidenceVerificationError(
                f"Fingerprint evidence payload {key} is invalid."
            )
    if (
        not payload["profileSequenceValid"]
        or not payload["identitySequenceValid"]
        or not payload["publicAlphaQualified"]
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence payload is not public-alpha qualified."
        )
    if payload["productionQualified"]:
        if (
            not payload["crossRealmConsistent"]
            or not payload["deviceTupleConsistent"]
            or not payload["networkPrivacyControlled"]
            or unavailable
            or unstable
            or limitations
        ):
            raise FingerprintEvidenceVerificationError(
                "Fingerprint evidence production qualification is incoherent."
            )
    elif limitations != ["strict-coherence-not-qualified"]:
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence limitations are incoherent."
        )
    if channel == "production" and not payload["productionQualified"]:
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence is not production qualified."
        )
    return payload

def _validate_critical_bundle_path(key: str, path: str) -> None:
    expected = EXACT_CRITICAL_FILE_PATHS.get(key)
    if expected is not None:
        expected_paths = (expected,) if isinstance(expected, str) else expected
        if path not in expected_paths:
            raise FingerprintEvidenceVerificationError(
                f"Candidate manifest {key} bundlePath is invalid."
            )
        return
    if key != "runtimeFramework":
        raise FingerprintEvidenceVerificationError(
            f"Candidate manifest {key} bundlePath is unsupported."
        )
    parts = path.split("/")
    if (
        len(parts) != 9
        or parts[:5]
        != [
            "Contents",
            "Resources",
            "NeAntik Browser.app",
            "Contents",
            "Frameworks",
        ]
        or parts[6] != "Versions"
        or parts[5] != f"{parts[8]}.framework"
        or parts[8]
        not in {
            "NeAntik Browser Framework",
            "NeVision Browser Framework",
        }
        or re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", parts[7]) is None
    ):
        raise FingerprintEvidenceVerificationError(
            "Candidate manifest runtimeFramework bundlePath is invalid."
        )

def _validate_candidate_manifest(
    value: Any,
) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = _require_exact_keys(
        value,
        MANIFEST_KEYS,
        "Candidate manifest",
    )
    _require_exact_integer(
        manifest.get("schemaVersion"),
        3,
        "Candidate manifest schemaVersion",
    )
    _require_exact_string(
        manifest.get("kind"),
        "neantik-direct-prepared-candidate",
        "Candidate manifest kind",
    )
    channel = manifest.get("releaseChannel")
    if channel not in {"public-alpha", "production"}:
        raise FingerprintEvidenceVerificationError(
            "Candidate manifest releaseChannel is invalid."
        )
    _validate_iso8601_date(
        manifest.get("preparedAt"),
        "Candidate manifest preparedAt",
    )
    bundle = _require_exact_keys(
        manifest.get("bundle"),
        {"name", "identifier", "version", "build"},
        "Candidate manifest bundle",
    )
    if (
        bundle.get("name") != "NeAntik.app"
        or bundle.get("identifier") != "app.neantik.desktop"
        or not isinstance(bundle.get("version"), str)
        or not bundle["version"]
        or not isinstance(bundle.get("build"), str)
        or not bundle["build"]
    ):
        raise FingerprintEvidenceVerificationError(
            "Candidate manifest bundle is invalid."
        )
    if manifest.get("postPreparationMutablePaths") != [
        "Contents/CodeResources"
    ]:
        raise FingerprintEvidenceVerificationError(
            "Candidate manifest mutable-path boundary is invalid."
        )
    if (
        not isinstance(manifest.get("boundary"), str)
        or not manifest["boundary"]
        or not isinstance(manifest.get("bundleInventory"), list)
        or not isinstance(manifest.get("criticalFiles"), dict)
    ):
        raise FingerprintEvidenceVerificationError(
            "Candidate manifest content is invalid."
        )
    critical_files = _require_exact_keys(
        manifest["criticalFiles"],
        CRITICAL_FILE_KEYS,
        "Candidate manifest criticalFiles",
    )
    for key, value in critical_files.items():
        entry = _validate_hashed_entry(
            value,
            f"Candidate manifest {key}",
        )
        _validate_critical_bundle_path(key, entry["bundlePath"])
    binding = validate_manifest_binding(
        manifest.get("fingerprintEvidence")
    )
    return manifest, binding

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
    manifest, binding = _validate_candidate_manifest(manifest)
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
        9,
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

    payload_value = _validate_release_payload(load_canonical_json(
        payload,
        maximum_bytes=MAXIMUM_PAYLOAD_BYTES,
        label="Fingerprint evidence payload",
    ))
    critical_files = manifest["criticalFiles"]
    runtime_executable = _validate_hashed_entry(
        critical_files.get("runtimeExecutable"),
        "Candidate runtime executable",
    )
    runtime_framework = _validate_hashed_entry(
        critical_files.get("runtimeFramework"),
        "Candidate runtime framework",
    )
    bundle = manifest["bundle"]
    if not (
        payload_value["releaseChannel"] == manifest["releaseChannel"]
        and payload_value["managerVersion"] == bundle["version"]
        and payload_value["managerBuild"] == bundle["build"]
        and hmac.compare_digest(
            payload_value["runtimeExecutableSHA256"],
            runtime_executable["sha256"],
        )
        and hmac.compare_digest(
            payload_value["runtimeFrameworkSHA256"],
            runtime_framework["sha256"],
        )
    ):
        raise FingerprintEvidenceVerificationError(
            "Fingerprint evidence metadata does not match the candidate."
        )
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
