import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import fingerprint_evidence_schema8 as MODULE  # noqa: E402


FIXTURE_PATH = (
    Path(__file__).resolve().parent
    / "fixtures"
    / "fingerprint-evidence-schema8-swift.json"
)
CLI = SCRIPTS / "verify-fingerprint-evidence-envelope.py"


def fixture_bytes() -> tuple[dict[str, object], bytes, bytes, bytes]:
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    return (
        fixture,
        base64.b64decode(fixture["manifestBase64"], validate=True),
        base64.b64decode(fixture["envelopeBase64"], validate=True),
        base64.b64decode(fixture["payloadBase64"], validate=True),
    )


def der_integer(value: int) -> bytes:
    encoded = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if encoded[0] & 0x80:
        encoded = b"\x00" + encoded
    return b"\x02" + bytes([len(encoded)]) + encoded


def der_signature(r: int, s: int) -> bytes:
    body = der_integer(r) + der_integer(s)
    return b"\x30" + bytes([len(body)]) + body


class FingerprintEvidenceSchema8Tests(unittest.TestCase):
    def test_manifest_binding_validation_is_exact_and_on_curve(self) -> None:
        _, manifest, _, _ = fixture_bytes()
        binding = json.loads(manifest)["fingerprintEvidence"]
        self.assertEqual(
            MODULE.validate_manifest_binding(binding),
            binding,
        )
        public_key = base64.b64decode(
            binding["publicKeyX963"],
            validate=True,
        )
        off_curve = b"\x04" + (b"\x00" * 64)
        invalid_bindings = []
        for changes in (
            {"schemaVersion": True},
            {"algorithm": "P256"},
            {"authorityKeyID": hashlib.sha256(public_key).hexdigest().upper()},
            {"authorityKeyID": "0" * 64},
            {"sessionID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},
            {"challenge": base64.b64encode(b"a" * 31).decode("ascii")},
            {
                "publicKeyX963": base64.b64encode(off_curve).decode("ascii"),
                "authorityKeyID": hashlib.sha256(off_curve).hexdigest(),
            },
        ):
            candidate = dict(binding)
            candidate.update(changes)
            invalid_bindings.append(candidate)
        missing = dict(binding)
        missing.pop("challenge")
        invalid_bindings.append(missing)
        extra = dict(binding)
        extra["unknown"] = True
        invalid_bindings.append(extra)

        for index, candidate in enumerate(invalid_bindings):
            with self.subTest(index=index):
                with self.assertRaises(
                    MODULE.FingerprintEvidenceVerificationError
                ):
                    MODULE.validate_manifest_binding(candidate)

    def test_off_curve_manifest_fails_before_openssl(self) -> None:
        _, manifest, envelope, _ = fixture_bytes()
        value = json.loads(manifest)
        off_curve = b"\x04" + (b"\x00" * 64)
        value["fingerprintEvidence"]["publicKeyX963"] = (
            base64.b64encode(off_curve).decode("ascii")
        )
        value["fingerprintEvidence"]["authorityKeyID"] = (
            hashlib.sha256(off_curve).hexdigest()
        )
        with mock.patch.object(MODULE, "_verify_with_openssl") as verifier:
            with self.assertRaisesRegex(
                MODULE.FingerprintEvidenceVerificationError,
                "not on",
            ):
                MODULE.verify_fingerprint_evidence(
                    candidate_manifest_raw=MODULE.canonical_json_bytes(value),
                    envelope_raw=envelope,
                )
        verifier.assert_not_called()

    def test_swift_cryptokit_fixture_verifies_with_openssl(self) -> None:
        fixture, manifest, envelope, payload = fixture_bytes()
        result = MODULE.verify_fingerprint_evidence(
            candidate_manifest_raw=manifest,
            envelope_raw=envelope,
        )
        expected = fixture["expected"]

        self.assertEqual(result.payload, payload)
        self.assertEqual(
            result.candidate_manifest_sha256,
            expected["candidateManifestSHA256"],
        )
        self.assertEqual(result.payload_sha256, expected["payloadSHA256"])
        self.assertEqual(
            result.challenge_sha256,
            expected["challengeSHA256"],
        )
        self.assertEqual(
            result.authority_key_id,
            expected["authorityKeyID"],
        )
        self.assertEqual(
            result.authenticated_evidence_id,
            expected["authenticatedEvidenceID"],
        )
        self.assertEqual(
            result.transport_sha256,
            expected["transportSHA256"],
        )
        self.assertEqual(
            base64.b64encode(result.transcript).decode("ascii"),
            expected["transcriptBase64"],
        )
        openssl_envelope = json.loads(envelope)
        openssl_envelope["authentication"]["signatureDER"] = fixture[
            "opensslSignatureBase64"
        ]
        openssl_raw = MODULE.canonical_json_bytes(openssl_envelope)
        openssl_result = MODULE.verify_fingerprint_evidence(
            candidate_manifest_raw=manifest,
            envelope_raw=openssl_raw,
        )
        self.assertEqual(
            openssl_result.transport_sha256,
            fixture["opensslTransportSHA256"],
        )
        self.assertEqual(
            hashlib.sha256(openssl_raw).hexdigest(),
            fixture["opensslTransportSHA256"],
        )

    def test_payload_change_invalidates_signature(self) -> None:
        _, manifest, envelope, _ = fixture_bytes()
        value = json.loads(envelope)
        payload = json.loads(base64.b64decode(value["payload"]))
        payload["runtimeName"] = "Tampered Browser"
        value["payload"] = base64.b64encode(
            MODULE.canonical_json_bytes(payload)
        ).decode("ascii")
        tampered = MODULE.canonical_json_bytes(value)

        with self.assertRaisesRegex(
            MODULE.FingerprintEvidenceVerificationError,
            "signature is invalid",
        ):
            MODULE.verify_fingerprint_evidence(
                candidate_manifest_raw=manifest,
                envelope_raw=tampered,
            )

    def test_high_s_twin_is_rejected_before_openssl(self) -> None:
        _, manifest, envelope, _ = fixture_bytes()
        value = json.loads(envelope)
        signature = base64.b64decode(
            value["authentication"]["signatureDER"],
            validate=True,
        )
        r, low_s = MODULE.parse_strict_p256_der(signature)
        high_s = MODULE.P256_ORDER - low_s
        self.assertGreater(high_s, MODULE.P256_HALF_ORDER)
        value["authentication"]["signatureDER"] = base64.b64encode(
            der_signature(r, high_s)
        ).decode("ascii")

        with self.assertRaisesRegex(
            MODULE.FingerprintEvidenceVerificationError,
            "low-S",
        ):
            MODULE.verify_fingerprint_evidence(
                candidate_manifest_raw=manifest,
                envelope_raw=MODULE.canonical_json_bytes(value),
            )

    def test_duplicate_noncanonical_and_escaped_manifest_fail(self) -> None:
        _, manifest, envelope, _ = fixture_bytes()
        candidates = [
            manifest + b" ",
            manifest.replace(
                b"{",
                b'{"schemaVersion":3,',
                1,
            ),
            manifest.replace(
                b"Contents/MacOS/NeAntik",
                b"Contents\\/MacOS\\/NeAntik",
            ),
        ]
        for candidate in candidates:
            with self.subTest(candidate=candidate[:40]):
                with self.assertRaises(
                    MODULE.FingerprintEvidenceVerificationError
                ):
                    MODULE.verify_fingerprint_evidence(
                        candidate_manifest_raw=candidate,
                        envelope_raw=envelope,
                    )

    def test_strict_der_rejects_noncanonical_scalars_and_trailing_data(
        self,
    ) -> None:
        invalid = [
            b"",
            b"\x30\x06\x02\x01\x00\x02\x01\x01",
            b"\x30\x07\x02\x02\x00\x01\x02\x01\x01",
            der_signature(1, 1) + b"\x00",
            der_signature(MODULE.P256_ORDER, 1),
            der_signature(1, MODULE.P256_HALF_ORDER + 1),
        ]
        for signature in invalid:
            with self.subTest(signature=signature.hex()):
                with self.assertRaises(
                    MODULE.FingerprintEvidenceVerificationError
                ):
                    MODULE.parse_strict_p256_der(signature)

    def test_missing_fixed_openssl_fails_closed(self) -> None:
        _, manifest, envelope, _ = fixture_bytes()
        with mock.patch.object(
            MODULE,
            "FIXED_OPENSSL_PATH",
            Path("/private/tmp/does-not-exist-openssl"),
        ):
            with self.assertRaisesRegex(
                MODULE.FingerprintEvidenceVerificationError,
                "OpenSSL verifier is unavailable",
            ):
                MODULE.verify_fingerprint_evidence(
                    candidate_manifest_raw=manifest,
                    envelope_raw=envelope,
                )

    def test_wire_uuid_is_uppercase_and_transcript_form_is_lowercase(
        self,
    ) -> None:
        wire = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        self.assertEqual(
            MODULE._canonical_wire_uuid(wire, "test UUID"),
            wire,
        )
        with self.assertRaisesRegex(
            MODULE.FingerprintEvidenceVerificationError,
            "uppercase",
        ):
            MODULE._canonical_wire_uuid(wire.lower(), "test UUID")

    def test_manifest_requires_root_schema_three(self) -> None:
        _, manifest, envelope, _ = fixture_bytes()
        for schema_version in (2, 4):
            candidate = json.loads(manifest)
            candidate["schemaVersion"] = schema_version
            with self.subTest(schema_version=schema_version):
                with self.assertRaisesRegex(
                    MODULE.FingerprintEvidenceVerificationError,
                    "schemaVersion",
                ):
                    MODULE.verify_fingerprint_evidence(
                        candidate_manifest_raw=MODULE.canonical_json_bytes(
                            candidate
                        ),
                        envelope_raw=envelope,
                    )

    def test_minimal_schema_marker_is_not_a_release_payload(self) -> None:
        with self.assertRaisesRegex(
            MODULE.FingerprintEvidenceVerificationError,
            "key set",
        ):
            MODULE._validate_release_payload({"schemaVersion": 1})

    def test_release_payload_rejects_private_fields_and_loose_timestamps(
        self,
    ) -> None:
        _, _, _, payload = fixture_bytes()
        report = json.loads(payload)
        invalid_reports = []
        with_unknown_report = dict(report)
        with_unknown_report["unknown"] = True
        invalid_reports.append(with_unknown_report)
        with_private_profile = dict(report)
        with_private_profile["profileName"] = "Личный профиль"
        invalid_reports.append(with_private_profile)
        with_unknown_surface = json.loads(payload)
        with_unknown_surface["criticalSurfaces"]["profileSeed"] = (
            "stable-different"
        )
        invalid_reports.append(with_unknown_surface)
        for invalid_date in (
            "2026-07-30Z",
            "2026-W31-4T00:00:00Z",
            "2026-07-30 00:00:00Z",
        ):
            with_invalid_date = json.loads(payload)
            with_invalid_date["createdAt"] = invalid_date
            invalid_reports.append(with_invalid_date)
        for report_value in invalid_reports:
            with self.subTest(report=report_value):
                with self.assertRaises(
                    MODULE.FingerprintEvidenceVerificationError
                ):
                    MODULE._validate_release_payload(report_value)

    def test_legacy_raw_schema7_payload_is_rejected(self) -> None:
        legacy = {
            "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "createdAt": "2026-07-30T00:00:00Z",
            "auditSchemaVersion": 7,
            "runtimeName": "NeAntik Browser",
            "runtimeFlavor": "fingerprintChromium",
            "firstInitial": {},
            "second": {},
            "firstRepeat": {},
        }
        with self.assertRaisesRegex(
            MODULE.FingerprintEvidenceVerificationError,
            "key set",
        ):
            MODULE._validate_release_payload(legacy)

    def test_bounded_reader_rejects_oversized_symlink_and_nonregular(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            oversized = root / "oversized.json"
            with oversized.open("wb") as handle:
                handle.truncate(MODULE.MAXIMUM_MANIFEST_BYTES + 1)
            target = root / "target.json"
            target.write_text("{}", encoding="utf-8")
            symlink = root / "link.json"
            symlink.symlink_to(target)
            fifo = root / "pipe"
            os.mkfifo(fifo)
            for path in (oversized, symlink, fifo):
                with self.subTest(path=path.name):
                    with self.assertRaises(
                        MODULE.FingerprintEvidenceVerificationError
                    ):
                        MODULE.read_bounded_regular_file(
                            path,
                            maximum_bytes=MODULE.MAXIMUM_MANIFEST_BYTES,
                            label="Candidate manifest",
                        )

    def test_bounded_reader_rejects_same_size_metadata_race(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.json"
            path.write_bytes(b"{}")
            real = path.stat()
            initial = types.SimpleNamespace(
                st_mode=real.st_mode,
                st_nlink=real.st_nlink,
                st_size=real.st_size,
                st_dev=real.st_dev,
                st_ino=real.st_ino,
                st_mtime_ns=real.st_mtime_ns,
                st_ctime_ns=real.st_ctime_ns,
            )
            changed = types.SimpleNamespace(
                st_mode=real.st_mode,
                st_nlink=real.st_nlink,
                st_size=real.st_size,
                st_dev=real.st_dev,
                st_ino=real.st_ino,
                st_mtime_ns=real.st_mtime_ns + 1,
                st_ctime_ns=real.st_ctime_ns,
            )
            with mock.patch.object(
                MODULE.os,
                "fstat",
                side_effect=[initial, changed],
            ):
                with self.assertRaisesRegex(
                    MODULE.FingerprintEvidenceVerificationError,
                    "changed",
                ):
                    MODULE.read_bounded_regular_file(
                        path,
                        maximum_bytes=MODULE.MAXIMUM_MANIFEST_BYTES,
                        label="Candidate manifest",
                    )

    def test_cli_cannot_override_openssl_and_sanitizes_read_errors(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_openssl = root / "fake-openssl"
            fake_openssl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_openssl.chmod(0o755)
            missing_manifest = root / "private-manifest-name.json"
            missing_envelope = root / "private-envelope-name.json"
            override = subprocess.run(
                [
                    sys.executable,
                    str(CLI),
                    "--manifest",
                    str(missing_manifest),
                    "--envelope",
                    str(missing_envelope),
                    "--openssl",
                    str(fake_openssl),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            sanitized = subprocess.run(
                [
                    sys.executable,
                    str(CLI),
                    "--manifest",
                    str(missing_manifest),
                    "--envelope",
                    str(missing_envelope),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertNotEqual(override.returncode, 0)
        self.assertIn("invalid command arguments", override.stderr)
        self.assertNotIn(str(fake_openssl), override.stderr)
        self.assertNotEqual(sanitized.returncode, 0)
        self.assertNotIn(str(root), sanitized.stderr)
        self.assertNotIn("private-manifest-name", sanitized.stderr)

    def test_cli_returns_only_public_hash_summary(self) -> None:
        fixture, manifest, envelope, _ = fixture_bytes()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path = root / "candidate.json"
            envelope_path = root / "evidence.json"
            manifest_path.write_bytes(manifest)
            envelope_path.write_bytes(envelope)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(CLI),
                    "--manifest",
                    str(manifest_path),
                    "--envelope",
                    str(envelope_path),
                    "--json",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        summary = json.loads(completed.stdout)
        self.assertEqual(
            summary["authenticatedEvidenceID"],
            fixture["expected"]["authenticatedEvidenceID"],
        )
        self.assertNotIn("payload", summary)
        self.assertNotIn("signature", summary)
        self.assertNotIn("challenge", summary)
        self.assertNotIn("authorityKeyID", summary)
        self.assertNotIn("sessionID", summary)


if __name__ == "__main__":
    unittest.main()
