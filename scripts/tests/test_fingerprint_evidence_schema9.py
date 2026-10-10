import base64
import copy
import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fingerprint_evidence as dispatch
import fingerprint_evidence_schema8 as legacy
import fingerprint_evidence_schema9 as current

FIXTURES = Path(__file__).resolve().parent / "fixtures"
def fixture(version):
    f = json.loads((FIXTURES / f"fingerprint-evidence-schema{version}-swift.json").read_text())
    return tuple(base64.b64decode(f[k], validate=True) for k in
                 ("manifestBase64", "envelopeBase64", "payloadBase64"))

class SemanticEvidenceTests(unittest.TestCase):
    def test_both_original_contracts_and_stable_same_v9(self):
        for version in (8, 9):
            manifest, envelope, payload = fixture(version)
            self.assertEqual(dispatch.verify_fingerprint_evidence(
                candidate_manifest_raw=manifest, envelope_raw=envelope).payload, payload)
        p = json.loads(fixture(9)[2])
        self.assertEqual(p["criticalSurfaces"]["webgl_pixels"], "stable-same")
        self.assertEqual(p["verdict"], "partial")
        self.assertEqual(p["changedCriticalKeys"], ["canvas"])

    def test_no_version_or_binding_fallback(self):
        m8, e8, _ = fixture(8); m9, e9, _ = fixture(9)
        for manifest, envelope in ((m8, e9), (m9, e8)):
            with self.assertRaises(dispatch.FingerprintEvidenceVerificationError):
                dispatch.verify_fingerprint_evidence(candidate_manifest_raw=manifest, envelope_raw=envelope)
        for schema in (False, 0, 3, 10):
            manifest = json.loads(m9); manifest["fingerprintEvidence"]["schemaVersion"] = schema
            with self.assertRaises(dispatch.FingerprintEvidenceVerificationError):
                dispatch.verify_fingerprint_evidence(candidate_manifest_raw=current.canonical_json_bytes(manifest), envelope_raw=e9)

    def test_legacy_stable_same_still_refused(self):
        value = json.loads(fixture(8)[2]); value["criticalSurfaces"]["webgl_pixels"] = "stable-same"
        value["changedCriticalKeys"] = ["canvas"]
        with self.assertRaises(legacy.FingerprintEvidenceVerificationError):
            legacy._validate_release_payload(value)

    def test_semantic_policy_and_tuple_are_exact(self):
        original = json.loads(fixture(9)[0])["fingerprintEvidence"]
        for key, bad in (("semanticPolicyID", "unknown"), ("auditSchemaVersion", 7),
                         ("payloadSchemaVersion", 1), ("evidenceSchemaVersion", 8),
                         ("evidenceSchemaVersion", True), ("challenge", "bad")):
            value = copy.deepcopy(original); value[key] = bad
            with self.assertRaises(current.FingerprintEvidenceVerificationError, msg=key):
                current.validate_manifest_binding(value)
        value = copy.deepcopy(original); value.pop("semanticPolicyID")
        with self.assertRaises(current.FingerprintEvidenceVerificationError):
            current.validate_manifest_binding(value)

    def test_payload_negatives_and_no_artificial_uniqueness(self):
        original = json.loads(fixture(9)[2])
        value = copy.deepcopy(original); value["criticalSurfaces"] = dict.fromkeys(value["criticalSurfaces"], "stable-same")
        value["changedCriticalKeys"] = []; value["verdict"] = "unchanged"
        self.assertEqual(current._validate_release_payload(value)["changedCriticalKeys"], [])
        for key, bad in (("semanticPolicyID", "unknown"), ("auditSchemaVersion", 7),
                         ("schemaVersion", 1), ("criticalObservationsStable", False),
                         ("criticalObservationsStable", 1), ("profileSequenceValid", False),
                         ("identitySequenceValid", False), ("runtimeCodeSignatureValid", False),
                         ("verdict", "verified"), ("changedCriticalKeys", ["canvas", "webgl_pixels"])):
            value = copy.deepcopy(original); value[key] = bad
            with self.assertRaises(current.FingerprintEvidenceVerificationError, msg=key):
                current._validate_release_payload(value)
        for state in ("unavailable", "unstable", "error", ""):
            value = copy.deepcopy(original); value["criticalSurfaces"]["webgl_pixels"] = state
            with self.assertRaises(current.FingerprintEvidenceVerificationError):
                current._validate_release_payload(value)
        for key in ("crossRealmConsistent", "deviceTupleConsistent", "networkPrivacyControlled"):
            value = copy.deepcopy(original); value.update(productionQualified=True, limitations=[],
                unavailableRequiredKeys=[], releaseChannel="production", crossRealmConsistent=True,
                deviceTupleConsistent=True, networkPrivacyControlled=True)
            value[key] = False
            with self.assertRaises(current.FingerprintEvidenceVerificationError, msg=key):
                current._validate_release_payload(value)

    def test_bad_signature_manifest_and_domain(self):
        manifest, envelope, _ = fixture(9)
        value = json.loads(envelope)
        for mutate in (lambda x: x.update(schemaVersion=8),
                       lambda x: x["authentication"].update(candidateManifestSHA256="0"*64),
                       lambda x: x["authentication"].update(challengeSHA256="0"*64),
                       lambda x: x["authentication"].update(keyID="0"*64)):
            item = copy.deepcopy(value); mutate(item)
            with self.assertRaises(current.FingerprintEvidenceVerificationError):
                dispatch.verify_fingerprint_evidence(candidate_manifest_raw=manifest,
                    envelope_raw=current.canonical_json_bytes(item))
        # Same key and valid DER do not make a signature portable across v8/v9.
        item = copy.deepcopy(value)
        item["authentication"]["signatureDER"] = json.loads(fixture(8)[1])["authentication"]["signatureDER"]
        with self.assertRaises(current.FingerprintEvidenceVerificationError):
            dispatch.verify_fingerprint_evidence(candidate_manifest_raw=manifest,
                envelope_raw=current.canonical_json_bytes(item))

if __name__ == "__main__": unittest.main()
