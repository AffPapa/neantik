from __future__ import annotations

import base64
import importlib.util
import hashlib
import json
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "verify-public-artifact-privacy.py"
SPEC = importlib.util.spec_from_file_location("verify_public_artifact_privacy", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

VERIFIER_TESTS = (
    Path(__file__).resolve().parent
    / "test_verify_gui_fingerprint_report.py"
)
VERIFIER_SPEC = importlib.util.spec_from_file_location(
    "public_privacy_gui_fixtures",
    VERIFIER_TESTS,
)
assert VERIFIER_SPEC and VERIFIER_SPEC.loader
VERIFIER_FIXTURES = importlib.util.module_from_spec(VERIFIER_SPEC)
sys.modules[VERIFIER_SPEC.name] = VERIFIER_FIXTURES
VERIFIER_SPEC.loader.exec_module(VERIFIER_FIXTURES)


class PublicArtifactPrivacyVerifierTests(unittest.TestCase):
    def test_single_public_file_is_verified_without_parent_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            public = root / "fingerprint-audit-summary.json"
            private = root / "fingerprint-audit.json"
            public.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "publicAlphaQualified": True,
                    }
                ),
                encoding="utf-8",
            )
            private.write_text(
                json.dumps(
                    {
                        "profileName": "must-not-be-scanned",
                    }
                ),
                encoding="utf-8",
            )

            result = MODULE.verify_public_artifact_privacy(
                artifact=public
            )

            self.assertEqual(result.scanned_entries, 1)
            self.assertEqual(result.artifact, public.resolve())

    def test_single_public_file_rejects_private_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "release.json"
            artifact.write_text(
                json.dumps({"proxyPassword": "actual-secret"}),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PublicArtifactPrivacyError,
                "private evidence",
            ):
                MODULE.verify_public_artifact_privacy(
                    artifact=artifact
                )

    def test_clean_directory_passes_without_scanning_sibling_private_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            public = root / "public"
            private = root / "private-evidence"
            public.mkdir()
            private.mkdir()
            (public / "summary.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "publicAlphaQualified": True,
                        "captures": 4,
                        "credentialStorage": "macOS Keychain",
                        "proxyCredentialsCollected": False,
                    }
                ),
                encoding="utf-8",
            )
            (private / "raw.json").write_text(
                json.dumps(
                    {
                        "firstInitial": {
                            "identityCode": "NA-DEADBEEF",
                            "values": {"canvas": "private"},
                        }
                    }
                ),
                encoding="utf-8",
            )

            result = MODULE.verify_public_artifact_privacy(artifact=public)

            self.assertEqual(result.scanned_entries, 1)

    def test_rejects_absolute_user_path_without_echoing_path_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            leaked = "/Users/alice/project/private-report.json"
            (public / "handoff.md").write_text(
                f"Report created at {leaked}\n",
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.PublicArtifactPrivacyError) as context:
                MODULE.verify_public_artifact_privacy(artifact=public)

            message = str(context.exception)
            self.assertIn("absolute /Users path", message)
            self.assertNotIn(leaked, message)

    def test_documentation_placeholders_and_source_examples_do_not_trigger(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            (public / "README.md").write_text(
                "Use /Users/<name>/project and identity format NA-XXXXXXXX.\n"
                "Example proxy password: <password>\n",
                encoding="utf-8",
            )
            tests = public / "tests"
            tests.mkdir()
            (tests / "verifier.py").write_text(
                'PATTERNS = ["/Users/<name>/private", "NA-XXXXXXXX", '
                '"http://user:fixture-password@proxy.invalid"]\n',
                encoding="utf-8",
            )

            MODULE.verify_public_artifact_privacy(artifact=public)

    def test_rejects_high_confidence_leaks_in_production_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            (public / "release.py").write_text(
                'HOME = "/Users/alice/private"\n'
                'PROXY = "http://real-user:real-password@proxy.invalid"\n',
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.PublicArtifactPrivacyError) as context:
                MODULE.verify_public_artifact_privacy(artifact=public)

            message = str(context.exception)
            self.assertIn("absolute /Users path", message)
            self.assertIn("proxy credentials in URL", message)

    def test_rejects_fingerprint_identity_and_raw_capture_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            (public / "fingerprint.json").write_text(
                json.dumps(
                    {
                        "firstInitial": {
                            "capturedAt": "2026-07-30T00:00:00Z",
                            "identityCode": "NA-13579BDF",
                            "profileID": "private-profile-id",
                            "values": {
                                "canvas": "private-canvas-hash",
                                "webrtc_candidates": "private-candidate-hash",
                            },
                        }
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.PublicArtifactPrivacyError) as context:
                MODULE.verify_public_artifact_privacy(artifact=public)

            message = str(context.exception)
            self.assertIn("fingerprint identity", message)
            self.assertIn("raw fingerprint capture values", message)
            self.assertNotIn("private-canvas-hash", message)

    def test_rejects_json_password_and_proxy_credentials_url(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            (public / "release.json").write_text(
                json.dumps(
                    {
                        "proxy": {
                            "host": "proxy.invalid",
                            "login": "real-user",
                            "password": "real-password-value",
                        }
                    }
                ),
                encoding="utf-8",
            )
            (public / "terminal.log").write_text(
                "proxy=http://real-user:another-password@proxy.invalid:8080\n",
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.PublicArtifactPrivacyError) as context:
                MODULE.verify_public_artifact_privacy(artifact=public)

            message = str(context.exception)
            self.assertIn("sensitive user, profile, browser or proxy data", message)
            self.assertIn("proxy credentials in URL", message)
            self.assertNotIn("real-password-value", message)
            self.assertNotIn("another-password", message)

    def test_plain_secret_and_test_password_values_are_not_placeholders(self) -> None:
        for password in ("secret", "test"):
            with self.subTest(password=password):
                with tempfile.TemporaryDirectory() as temporary:
                    public = Path(temporary)
                    (public / "release.json").write_text(
                        json.dumps({"proxy": {"password": password}}),
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(
                        MODULE.PublicArtifactPrivacyError,
                        "sensitive user, profile, browser or proxy data",
                    ):
                        MODULE.verify_public_artifact_privacy(
                            artifact=public
                        )

    def test_rejects_ini_proxy_password_and_absolute_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            (public / "release.ini").write_text(
                "home=/Users/alice/private\n"
                "proxy_password=actual-password\n",
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.PublicArtifactPrivacyError) as context:
                MODULE.verify_public_artifact_privacy(artifact=public)

            self.assertIn("absolute /Users path", str(context.exception))
            self.assertIn("proxy password", str(context.exception))

    def test_invalid_json_and_jsonl_fail_closed(self) -> None:
        for name, content in (
            ("release.json", '{"password": "value"'),
            ("release.jsonl", '{"safe": true}\n{"password":'),
        ):
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary:
                    public = Path(temporary)
                    (public / name).write_text(content, encoding="utf-8")

                    with self.assertRaisesRegex(
                        MODULE.PublicArtifactPrivacyError,
                        "invalid and cannot be privacy-verified",
                    ):
                        MODULE.verify_public_artifact_privacy(
                            artifact=public
                        )

    def test_verifies_exact_private_evidence_attestation_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            private = root / "fingerprint-audit.json"
            attestation = root / "fingerprint-audit-summary.json"
            integrated_app = VERIFIER_FIXTURES.write_integrated_app_fixture(
                root
            )
            report = VERIFIER_FIXTURES.production_report()
            expected_runtime = (
                MODULE.GUI_VERIFIER.expected_runtime_evidence_from_app(
                    integrated_app
                )
            )
            for key in (
                "managerVersion",
                "managerBuild",
                "runtimeVersion",
                "runtimeExecutableSHA256",
                "runtimeFrameworkSHA256",
            ):
                report[key] = expected_runtime[key]
            private_payload = (
                json.dumps(
                    report,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n"
            ).encode("utf-8")
            private.write_bytes(private_payload)
            summary = MODULE.GUI_VERIFIER.verification_summary(
                report,
                expected_runtime=expected_runtime,
            )
            attestation.write_text(
                json.dumps(
                    MODULE.expected_public_attestation(
                        report,
                        summary,
                        private_evidence_sha256=hashlib.sha256(
                            private_payload
                        ).hexdigest(),
                    )
                ),
                encoding="utf-8",
            )

            MODULE.verify_evidence_attestation_binding(
                private_evidence=private,
                attestation=attestation,
                integrated_app=integrated_app,
            )
            private.write_bytes(b'{"private":"tampered"}\n')

            with self.assertRaisesRegex(
                MODULE.PublicArtifactPrivacyError,
                "does not match",
            ):
                MODULE.verify_evidence_attestation_binding(
                    private_evidence=private,
                    attestation=attestation,
                    integrated_app=integrated_app,
                )

    def test_rejects_self_consistent_attestation_for_wrong_current_app_version(
        self,
    ) -> None:
        for key, value in (
            ("managerVersion", "999.0"),
            ("runtimeVersion", "999.0.0.0"),
        ):
            with self.subTest(key=key):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    integrated_app = (
                        VERIFIER_FIXTURES.write_integrated_app_fixture(root)
                    )
                    expected_runtime = (
                        MODULE.GUI_VERIFIER.expected_runtime_evidence_from_app(
                            integrated_app
                        )
                    )
                    report = VERIFIER_FIXTURES.production_report()
                    for runtime_key in (
                        "managerVersion",
                        "managerBuild",
                        "runtimeVersion",
                        "runtimeExecutableSHA256",
                        "runtimeFrameworkSHA256",
                    ):
                        report[runtime_key] = expected_runtime[runtime_key]
                    report[key] = value
                    private_payload = (
                        json.dumps(
                            report,
                            ensure_ascii=False,
                            indent=2,
                            sort_keys=True,
                        )
                        + "\n"
                    ).encode("utf-8")
                    private = root / "fingerprint-audit.json"
                    private.write_bytes(private_payload)
                    summary = MODULE.GUI_VERIFIER.verification_summary(
                        report,
                        expected_runtime=None,
                    )
                    attestation = root / "fingerprint-audit-summary.json"
                    attestation.write_text(
                        json.dumps(
                            MODULE.expected_public_attestation(
                                report,
                                summary,
                                private_evidence_sha256=hashlib.sha256(
                                    private_payload
                                ).hexdigest(),
                            )
                        ),
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(
                        MODULE.PublicArtifactPrivacyError,
                        "not semantically qualified",
                    ):
                        MODULE.verify_evidence_attestation_binding(
                            private_evidence=private,
                            attestation=attestation,
                            integrated_app=integrated_app,
                        )

    def test_rejects_unknown_database_and_binary_suffixes(self) -> None:
        for name in ("private.db", "cookies.sqlite", "opaque.bin"):
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary:
                    public = Path(temporary)
                    (public / name).write_bytes(b"private-data")

                    with self.assertRaisesRegex(
                        MODULE.PublicArtifactPrivacyError,
                        "Unknown public artifact file type",
                    ):
                        MODULE.verify_public_artifact_privacy(
                            artifact=public
                        )

    def test_safe_binary_allowlist_checks_file_signature(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            (public / "icon.png").write_bytes(
                b"\x89PNG\r\n\x1a\nfixture"
            )
            MODULE.verify_public_artifact_privacy(artifact=public)
            (public / "fake.png").write_bytes(b"SQLite format 3\x00private")

            with self.assertRaisesRegex(
                MODULE.PublicArtifactPrivacyError,
                "invalid signature",
            ):
                MODULE.verify_public_artifact_privacy(artifact=public)

    def test_rejects_private_strings_in_full_binary_payload_directory_and_zip(
        self,
    ) -> None:
        fixtures = (
            ("leak.png", b"\x89PNG\r\n\x1a\n"),
            ("leak.pdf", b"%PDF-1.7\n"),
        )
        for name, signature in fixtures:
            with self.subTest(name=name, artifact="directory"):
                with tempfile.TemporaryDirectory() as temporary:
                    public = Path(temporary)
                    (public / name).write_bytes(
                        signature
                        + b"/Users/alice/private\n"
                        + b"proxyPassword=actual-secret\n"
                    )
                    with self.assertRaisesRegex(
                        MODULE.PublicArtifactPrivacyError,
                        "private evidence",
                    ):
                        MODULE.verify_public_artifact_privacy(
                            artifact=public
                        )
            with self.subTest(name=name, artifact="zip"):
                with tempfile.TemporaryDirectory() as temporary:
                    archive = Path(temporary) / "public.zip"
                    with zipfile.ZipFile(archive, "w") as output:
                        output.writestr(
                            f"public/{name}",
                            signature
                            + b"/Users/alice/private\n"
                            + b"proxyPassword=actual-secret\n",
                        )
                    with self.assertRaisesRegex(
                        MODULE.PublicArtifactPrivacyError,
                        "private evidence",
                    ):
                        MODULE.verify_public_artifact_privacy(
                            artifact=archive
                        )

    def test_rejects_normalized_sensitive_json_classes_without_echoing_values(self) -> None:
        sensitive = {
            "cookies": ["cookie-secret"],
            "visited_url": "https://private.invalid/account",
            "browser-history": ["https://private.invalid/one"],
            "profileName": "Private profile",
            "profile_id": "private-profile-id",
            "fingerprintSeed": "private-seed",
            "proxy_host": "proxy.private.invalid",
            "proxyLogin": "private-login",
            "proxy-password": "private-password",
            "stableUserID": "stable-user-id",
            "install_id": "stable-install-id",
        }
        with tempfile.TemporaryDirectory() as temporary:
            public = Path(temporary)
            target = public / "private.json"
            target.write_text(json.dumps(sensitive), encoding="utf-8")

            with self.assertRaises(
                MODULE.PublicArtifactPrivacyError
            ) as context:
                MODULE.verify_public_artifact_privacy(artifact=public)

            message = str(context.exception)
            self.assertIn(
                "sensitive user, profile, browser or proxy data",
                message,
            )
            for secret in sensitive.values():
                if isinstance(secret, list):
                    secret = secret[0]
                self.assertNotIn(str(secret), message)

    def test_rejects_attestation_schema_drift(self) -> None:
        report = VERIFIER_FIXTURES.production_report()
        summary = MODULE.GUI_VERIFIER.verification_summary(
            report,
            expected_runtime=None,
        )
        payload = MODULE.expected_public_attestation(
            report,
            summary,
            private_evidence_sha256="a" * 64,
        )
        mutations = (
            ("extra", "value"),
            ("qualified", False),
            ("schemaVersion", 1),
            ("privateEvidenceSHA256", "not-a-hash"),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                candidate = dict(payload)
                candidate[key] = value
                with self.assertRaises(
                    MODULE.PublicArtifactPrivacyError
                ):
                    MODULE.validate_public_attestation(candidate)

    def test_authenticated_attestation_reverifies_exact_schema8(self) -> None:
        fixture_path = (
            Path(__file__).resolve().parent
            / "fixtures"
            / "fingerprint-evidence-schema8-swift.json"
        )
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        manifest_raw = base64.b64decode(
            fixture["manifestBase64"],
            validate=True,
        )
        envelope_raw = base64.b64decode(
            fixture["envelopeBase64"],
            validate=True,
        )
        verified = MODULE.EVIDENCE_SCHEMA.verify_fingerprint_evidence(
            candidate_manifest_raw=manifest_raw,
            envelope_raw=envelope_raw,
        )
        payload = MODULE.EVIDENCE_SCHEMA.load_canonical_json(
            verified.payload,
            maximum_bytes=MODULE.EVIDENCE_SCHEMA.MAXIMUM_PAYLOAD_BYTES,
            label="Fingerprint evidence payload",
        )
        attestation = MODULE.expected_authenticated_public_attestation(
            payload,
            verified,
        )
        expected_runtime = {
            "managerVersion": payload["managerVersion"],
            "managerBuild": payload["managerBuild"],
            "runtimeVersion": payload["runtimeVersion"],
            "runtimeExecutableSHA256":
                payload["runtimeExecutableSHA256"],
            "runtimeFrameworkSHA256":
                payload["runtimeFrameworkSHA256"],
        }
        with mock.patch.object(
            MODULE.GUI_VERIFIER,
            "expected_runtime_evidence_from_app",
            return_value=expected_runtime,
        ):
            result = (
                MODULE.verify_evidence_attestation_payload_binding(
                    private_payload=envelope_raw,
                    public_payload=attestation,
                    integrated_app=Path("/private/tmp/NeAntik.app"),
                    release_channel="public-alpha",
                    candidate_manifest_sha256=hashlib.sha256(
                        manifest_raw
                    ).hexdigest(),
                    candidate_manifest_raw=manifest_raw,
                )
            )
        self.assertEqual(
            result,
            fixture["expected"]["transportSHA256"],
        )

        tampered = dict(attestation)
        tampered["payloadSHA256"] = "0" * 64
        with mock.patch.object(
            MODULE.GUI_VERIFIER,
            "expected_runtime_evidence_from_app",
            return_value=expected_runtime,
        ):
            with self.assertRaisesRegex(
                MODULE.PublicArtifactPrivacyError,
                "do not match",
            ):
                MODULE.verify_evidence_attestation_payload_binding(
                    private_payload=envelope_raw,
                    public_payload=tampered,
                    integrated_app=Path(
                        "/private/tmp/NeAntik.app"
                    ),
                    release_channel="public-alpha",
                    candidate_manifest_sha256=hashlib.sha256(
                        manifest_raw
                    ).hexdigest(),
                    candidate_manifest_raw=manifest_raw,
                )

    def test_candidate_bound_release_rejects_legacy_schema2_raw_report(
        self,
    ) -> None:
        report = VERIFIER_FIXTURES.production_report()
        summary = MODULE.GUI_VERIFIER.verification_summary(
            report,
            expected_runtime=None,
        )
        private_payload = json.dumps(report).encode("utf-8")
        manifest_raw = b"{}"
        attestation = MODULE.expected_public_attestation(
            report,
            summary,
            private_evidence_sha256=hashlib.sha256(
                private_payload
            ).hexdigest(),
            candidate_manifest_sha256=hashlib.sha256(
                manifest_raw
            ).hexdigest(),
            release_channel="public-alpha",
        )

        with self.assertRaisesRegex(
            MODULE.PublicArtifactPrivacyError,
            "requires authenticated schema-8",
        ):
            MODULE.verify_evidence_attestation_payload_binding(
                private_payload=private_payload,
                public_payload=attestation,
                integrated_app=Path("/private/tmp/NeAntik.app"),
                release_channel="public-alpha",
                candidate_manifest_sha256=hashlib.sha256(
                    manifest_raw
                ).hexdigest(),
                candidate_manifest_raw=manifest_raw,
            )

    def test_zip_and_directory_have_same_privacy_verdict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            public = root / "public"
            public.mkdir()
            (public / "release.json").write_text(
                json.dumps({"status": "public-alpha", "version": "0.3.12"}),
                encoding="utf-8",
            )
            archive = root / "public.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.write(public / "release.json", "public/release.json")

            directory_result = MODULE.verify_public_artifact_privacy(artifact=public)
            archive_result = MODULE.verify_public_artifact_privacy(artifact=archive)

            self.assertEqual(directory_result.scanned_entries, 1)
            self.assertEqual(archive_result.scanned_entries, 1)

    def test_rejects_unsafe_zip_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "public.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("../private.txt", "not allowed")

            with self.assertRaisesRegex(
                MODULE.PublicArtifactPrivacyError,
                "ZIP entry path",
            ):
                MODULE.verify_public_artifact_privacy(artifact=archive)

    def test_rejects_duplicate_and_noncanonical_zip_members(self) -> None:
        cases = (
            ("duplicate", ("public/readme.txt", "public/readme.txt")),
            ("dot segment", ("public/./readme.txt",)),
            ("empty segment", ("public//readme.txt",)),
            ("backslash", (r"public\readme.txt",)),
        )
        for label, names in cases:
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as temporary:
                    archive = Path(temporary) / "public.zip"
                    with zipfile.ZipFile(archive, "w") as output:
                        for name in names:
                            output.writestr(name, "clean")
                    with self.assertRaises(
                        MODULE.PublicArtifactPrivacyError
                    ):
                        MODULE.verify_public_artifact_privacy(
                            artifact=archive
                        )

    def test_rejects_non_regular_zip_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "public.zip"
            fifo = zipfile.ZipInfo("public/fifo")
            fifo.create_system = 3
            fifo.external_attr = (stat.S_IFIFO | 0o600) << 16
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr(fifo, b"")
            with self.assertRaisesRegex(
                MODULE.PublicArtifactPrivacyError,
                "non-regular ZIP entry",
            ):
                MODULE.verify_public_artifact_privacy(artifact=archive)

    def test_rejects_zip_symlink_instead_of_skipping_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "public.zip"
            link = zipfile.ZipInfo("public/private-link")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr(link, "/Users/alice/private")

            with self.assertRaisesRegex(
                MODULE.PublicArtifactPrivacyError,
                "ZIP symlink",
            ):
                MODULE.verify_public_artifact_privacy(artifact=archive)


if __name__ == "__main__":
    unittest.main()
