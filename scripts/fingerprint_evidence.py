"""Closed version dispatch. No retry using a different evidence policy."""
from __future__ import annotations
from pathlib import Path
import sys
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import fingerprint_evidence_schema8 as historical
import fingerprint_evidence_schema9 as current
from fingerprint_evidence_schema8 import (
    FingerprintEvidenceVerificationError, MAXIMUM_ENVELOPE_BYTES,
    MAXIMUM_MANIFEST_BYTES, MAXIMUM_PAYLOAD_BYTES, MAXIMUM_ENROLLMENT_BINDING_BYTES,
    read_bounded_regular_file, load_canonical_json, canonical_json_bytes,
    validate_p256_public_key_x963, parse_strict_p256_der,
)

def _module_for_binding(value):
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int:
        raise FingerprintEvidenceVerificationError("Unsupported fingerprint binding schema.")
    if value["schemaVersion"] == 1:
        return historical
    if value["schemaVersion"] == 2:
        return current
    raise FingerprintEvidenceVerificationError("Unsupported fingerprint binding schema.")

def validate_manifest_binding(value):
    return _module_for_binding(value).validate_manifest_binding(value)

def load_enrollment_binding(path: Path):
    raw = read_bounded_regular_file(path, maximum_bytes=MAXIMUM_ENROLLMENT_BINDING_BYTES,
                                   label="Fingerprint enrollment binding")
    return validate_manifest_binding(load_canonical_json(raw,
        maximum_bytes=MAXIMUM_ENROLLMENT_BINDING_BYTES, label="Fingerprint enrollment binding"))

def _validate_candidate_manifest(value):
    if not isinstance(value, dict):
        raise FingerprintEvidenceVerificationError("Invalid candidate manifest.")
    return _module_for_binding(value.get("fingerprintEvidence"))._validate_candidate_manifest(value)

def _validate_release_payload(value):
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int:
        raise FingerprintEvidenceVerificationError("Unsupported release payload schema.")
    module = {1: historical, 2: current}.get(value["schemaVersion"])
    if module is None:
        raise FingerprintEvidenceVerificationError("Unsupported release payload schema.")
    return module._validate_release_payload(value)

def verify_fingerprint_evidence(*, candidate_manifest_raw, envelope_raw, timeout_seconds=10):
    manifest = load_canonical_json(candidate_manifest_raw,
        maximum_bytes=MAXIMUM_MANIFEST_BYTES, label="Candidate manifest")
    if not isinstance(manifest, dict):
        raise FingerprintEvidenceVerificationError("Invalid candidate manifest.")
    module = _module_for_binding(manifest.get("fingerprintEvidence"))
    return module.verify_fingerprint_evidence(candidate_manifest_raw=candidate_manifest_raw,
        envelope_raw=envelope_raw, timeout_seconds=timeout_seconds)
