import importlib.util
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-gui-fingerprint-report.py"
SPEC = importlib.util.spec_from_file_location("verify_gui_fingerprint_report", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


SHA_A = "a" * 64
SHA_B = "b" * 64


class VerifyGuiFingerprintReportTests(unittest.TestCase):
    def test_accepts_production_gui_report(self) -> None:
        summary = MODULE.verification_summary(production_report())

        self.assertTrue(summary["qualified"])
        self.assertTrue(summary["productionQualified"])
        self.assertEqual(summary["issues"], [])
        self.assertIn("webgl_pixels", summary["changedCriticalKeys"])
        self.assertEqual(
            summary["networkEvidenceScope"],
            "configured-route-webrtc-only",
        )
        self.assertFalse(summary["effectiveHTTPRouteObserved"])

    def test_accepts_future_runtime_when_tuple_matches_runtime_version(self) -> None:
        summary = MODULE.verification_summary(
            production_report(runtime_version="150.0.7871.186")
        )

        self.assertTrue(summary["qualified"])
        self.assertEqual(summary["issues"], [])

    def test_rejects_future_runtime_with_stale_user_agent_version(self) -> None:
        report = production_report(runtime_version="150.0.7871.186")
        report["firstInitial"]["values"]["user_agent"] = (
            "Mozilla/5.0 Chrome/144.0.7559.132 Safari/537.36"
        )

        issues = MODULE.production_release_issues(report)

        self.assertIn(
            "The profile A, first capture User-Agent does not match the compiled runtime version.",
            issues,
        )

    def test_rejects_future_runtime_with_stale_client_hints_version(self) -> None:
        report = production_report(runtime_version="150.0.7871.186")
        report["second"]["values"]["client_hints"] = (
            '{"architecture":"arm","bitness":"64","platform":"macOS",'
            '"platformVersion":"15.1.0","uaFullVersion":"144.0.7559.132"}'
        )

        issues = MODULE.production_release_issues(report)

        self.assertIn(
            "The profile B Client Hints uaFullVersion value does not match device tuple macbook-air-m4.",
            issues,
        )

    def test_accepts_report_bound_to_runtime_lock_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = write_runtime_lock_fixture(root)
            expected = MODULE.expected_runtime_evidence(
                MODULE.load_runtime_lock(lock_path),
                lock_path=lock_path,
            )

            summary = MODULE.verification_summary(
                production_report(),
                expected_runtime=expected,
            )

        self.assertTrue(summary["qualified"])
        self.assertEqual(summary["createdAt"], "2026-07-25T08:29:41Z")

    def test_rejects_report_with_runtime_executable_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = write_runtime_lock_fixture(root)
            expected = MODULE.expected_runtime_evidence(
                MODULE.load_runtime_lock(lock_path),
                lock_path=lock_path,
            )
            report = production_report()
            report["runtimeExecutableSHA256"] = "c" * 64

            issues = MODULE.production_release_issues(
                report,
                expected_runtime=expected,
            )

        self.assertIn(
            "The report runtime executable SHA-256 does not match the pinned runtime evidence.",
            issues,
        )

    def test_rejects_report_created_before_runtime_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = write_runtime_lock_fixture(
                root,
                runtime_created_at="2026-07-25T09:00:00Z",
            )
            expected = MODULE.expected_runtime_evidence(
                MODULE.load_runtime_lock(lock_path),
                lock_path=lock_path,
            )

            issues = MODULE.production_release_issues(
                production_report(),
                expected_runtime=expected,
            )

        self.assertIn(
            "The report or a capture predates the pinned runtime verification report.",
            issues,
        )

    def test_binds_report_to_freshly_hashed_distributed_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            integrated_app = write_integrated_app_fixture(Path(temporary))
            expected = MODULE.expected_runtime_evidence_from_app(integrated_app)
            report = production_report()
            report["runtimeExecutableSHA256"] = expected[
                "runtimeExecutableSHA256"
            ]
            report["runtimeFrameworkSHA256"] = expected[
                "runtimeFrameworkSHA256"
            ]

            summary = MODULE.verification_summary(
                report,
                expected_runtime=expected,
            )

        self.assertTrue(summary["qualified"])

    def test_rejects_distributed_runtime_binary_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            integrated_app = write_integrated_app_fixture(Path(temporary))
            executable = (
                integrated_app
                / "Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser"
            )
            executable.write_bytes(b"changed")

            with self.assertRaisesRegex(
                MODULE.FingerprintReportError,
                "do not match",
            ):
                MODULE.expected_runtime_evidence_from_app(integrated_app)

    def test_report_path_cannot_redirect_runtime_hashing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated_app = write_integrated_app_fixture(root)
            redirected = root / "redirected-runtime"
            redirected.write_bytes(b"runtime executable")
            report_path = (
                integrated_app
                / "Contents/Resources/NeAntikRuntimeEvidence/"
                "runtime-verification.json"
            )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["executable"]["path"] = str(redirected)
            report_path.write_text(json.dumps(report), encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.FingerprintReportError,
                "non-canonical executable path",
            ):
                MODULE.expected_runtime_evidence_from_app(integrated_app)

    def test_fixture_runtime_report_contains_no_local_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            integrated_app = write_integrated_app_fixture(Path(temporary))
            report_path = (
                integrated_app
                / "Contents/Resources/NeAntikRuntimeEvidence/"
                "runtime-verification.json"
            )
            report_text = report_path.read_text(encoding="utf-8")

        self.assertNotIn("/private/tmp/", report_text)
        self.assertNotIn("/var/folders/", report_text)
        self.assertNotIn('"path": "/', report_text)

    def test_rejects_distributed_patch_manifest_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            integrated_app = write_integrated_app_fixture(Path(temporary))
            manifest = (
                integrated_app
                / "Contents/Resources/NeAntikRuntimeEvidence/"
                "neantik-patch-series.json"
            )
            manifest.write_text('{"changed":true}\n', encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.FingerprintReportError,
                "neantik-patch-series.json",
            ):
                MODULE.expected_runtime_evidence_from_app(integrated_app)

    def test_rejects_unordered_capture_timestamps(self) -> None:
        report = production_report()
        report["second"]["capturedAt"] = "2026-07-25T08:29:37Z"

        issues = MODULE.production_release_issues(report)

        self.assertIn(
            "Capture timestamps are not ordered as direct control → A → B → A.",
            issues,
        )

    def test_rejects_direct_control_after_first_capture(self) -> None:
        report = production_report()
        report["webrtcDirectControl"]["capturedAt"] = (
            "2026-07-25T08:29:39Z"
        )
        issues = MODULE.production_release_issues(report)
        self.assertIn(
            "Capture timestamps are not ordered as direct control → A → B → A.",
            issues,
        )

    def test_rejects_capture_timestamp_after_report_created_at(self) -> None:
        report = production_report()
        report["firstRepeat"]["capturedAt"] = "2026-07-25T08:30:00Z"

        issues = MODULE.production_release_issues(report)

        self.assertIn("A capture timestamp is later than the report createdAt timestamp.", issues)

    def test_rejects_headless_diagnostic_report(self) -> None:
        report = production_report()
        report["executionMode"] = "headless-single-process-diagnostic"

        issues = MODULE.production_release_issues(report)

        self.assertIn("The report was captured in diagnostic mode.", issues)

    def test_rejects_unavailable_webgl(self) -> None:
        report = production_report()
        for capture_key in ["firstInitial", "second", "firstRepeat"]:
            values = report[capture_key]["values"]
            values["webgl_pixels"] = "unavailable"
            values["webgl_vendor"] = "unavailable"
            values["webgl_renderer"] = "unavailable"

        issues = MODULE.production_release_issues(report)

        self.assertTrue(
            any(issue.startswith("Required browser surfaces are unavailable") for issue in issues)
        )
        self.assertIn("WebGL pixels did not differ between profiles.", issues)

    def test_rejects_unstable_repeat_capture(self) -> None:
        report = production_report()
        report["firstRepeat"]["values"]["canvas"] = "canvas-random"

        issues = MODULE.production_release_issues(report)

        self.assertIn("The critical-surface verdict is not verified.", issues)
        self.assertTrue(
            any(issue.startswith("Required browser surfaces are unstable") for issue in issues)
        )

    def test_cross_realm_mismatch_fails_strict_but_not_public_alpha(self) -> None:
        report = production_report()
        report["firstInitial"]["values"]["worker_platform"] = "Win32"
        report["firstRepeat"]["values"]["worker_platform"] = "Win32"

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The profile A, first capture platform value disagrees with worker_platform.",
            summary["productionIssues"],
        )
        self.assertEqual(
            MODULE.qualification_issues(summary, require_production=False),
            [],
        )
        self.assertIn(
            "The profile A, first capture platform value disagrees with worker_platform.",
            MODULE.qualification_issues(summary, require_production=True),
        )

    def test_missing_worker_memory_fails_strict_but_not_public_alpha(self) -> None:
        report = production_report()
        for capture_key in ["firstInitial", "second", "firstRepeat"]:
            del report[capture_key]["values"]["worker_device_memory"]

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "Required browser surfaces are unavailable: worker_device_memory.",
            summary["productionIssues"],
        )

    def test_worker_memory_mismatch_fails_strict_but_not_public_alpha(self) -> None:
        report = production_report()
        report["firstInitial"]["values"]["worker_device_memory"] = "4"
        report["firstRepeat"]["values"]["worker_device_memory"] = "4"

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The profile A, first capture device_memory value disagrees with worker_device_memory.",
            summary["productionIssues"],
        )

    def test_locale_mismatch_fails_strict_but_not_public_alpha(self) -> None:
        report = production_report()
        for capture_key in ["firstInitial", "firstRepeat"]:
            report[capture_key]["values"]["languages"] = "ru-RU,ru"
            report[capture_key]["values"]["worker_languages"] = "ru-RU,ru"
            report[capture_key]["values"][
                "primary_locale_core"
            ] = "ru-Cyrl-RU"
            report[capture_key]["values"][
                "worker_primary_locale_core"
            ] = "ru-Cyrl-RU"

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The profile A, first capture primary_locale_core "
            "disagrees with intl_locale_core.",
            summary["productionIssues"],
        )
        self.assertIn(
            "The profile A, first capture worker_primary_locale_core "
            "disagrees with worker_intl_locale_core.",
            summary["productionIssues"],
        )

    def test_locale_canonicalization_accepts_equivalent_identifiers(self) -> None:
        for languages, intl_locale, locale_core in (
            ("en_us,en", "en-US", "en-Latn-US"),
            ("es-419,es", "es-419", "es-Latn-419"),
            ("zh-Hant,zh", "zh-Hant", "zh-Hant-TW"),
            ("sr-Latn,sr", "sr-Latn", "sr-Latn-RS"),
            ("en-US,en", "en-US-u-hc-h12", "en-Latn-US"),
            ("de-DE-1996,de", "de-DE", "de-Latn-DE"),
            ("sl-rozaj-biske,sl", "sl", "sl-Latn-SI"),
            ("en-Latn-US,en", "en", "en-Latn-US"),
            ("es-Latn-419,es", "es", "es-Latn-419"),
            ("fil-Latn-PH,fil", "fil", "fil-Latn-PH"),
            ("iw-IL,iw", "he-IL", "he-Hebr-IL"),
            ("in-ID,in", "id-ID", "id-Latn-ID"),
            ("ji,ji", "yi", "yi-Hebr-UA"),
        ):
            with self.subTest(
                languages=languages,
                intl_locale=intl_locale,
            ):
                report = production_report()
                for capture_key in ["firstInitial", "second", "firstRepeat"]:
                    values = report[capture_key]["values"]
                    values["languages"] = languages
                    values["worker_languages"] = languages
                    values["intl_locale"] = intl_locale
                    values["worker_intl_locale"] = intl_locale
                    values["primary_locale_core"] = locale_core
                    values["intl_locale_core"] = locale_core
                    values["worker_primary_locale_core"] = locale_core
                    values["worker_intl_locale_core"] = locale_core

                summary = MODULE.verification_summary(report)

                self.assertTrue(summary["qualified"])
                self.assertTrue(summary["productionQualified"])

    def test_locale_core_rejects_region_or_script_contradictions(self) -> None:
        for languages, intl_locale, primary_core, intl_core in (
            ("en-US,en", "en-GB", "en-Latn-US", "en-Latn-GB"),
            ("pt-BR,pt", "pt-PT", "pt-Latn-BR", "pt-Latn-PT"),
            ("zh-Hans-CN,zh", "zh-Hant-TW", "zh-Hans-CN", "zh-Hant-TW"),
            ("sr-Latn-RS,sr", "sr-Cyrl-RS", "sr-Latn-RS", "sr-Cyrl-RS"),
        ):
            with self.subTest(languages=languages, intl_locale=intl_locale):
                report = production_report()
                for capture_key in ["firstInitial", "firstRepeat"]:
                    values = report[capture_key]["values"]
                    for prefix in ("", "worker_"):
                        values[f"{prefix}languages"] = languages
                        values[f"{prefix}intl_locale"] = intl_locale
                        values[f"{prefix}primary_locale_core"] = primary_core
                        values[f"{prefix}intl_locale_core"] = intl_core

                summary = MODULE.verification_summary(report)

                self.assertTrue(summary["qualified"])
                self.assertFalse(summary["productionQualified"])
                self.assertTrue(
                    any(
                        "primary_locale_core disagrees with intl_locale_core"
                        in issue
                        for issue in summary["productionIssues"]
                    )
                )

    def test_non_ascii_locale_identifiers_fail_strict(self) -> None:
        report = production_report()
        for capture_key in ["firstInitial", "firstRepeat"]:
            values = report[capture_key]["values"]
            values["languages"] = "еn-US,en"
            values["worker_languages"] = "еn-US,en"
            values["intl_locale"] = "еn-US"
            values["worker_intl_locale"] = "еn-US"

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertTrue(
            any(
                "not supported locale identifiers" in issue
                for issue in summary["productionIssues"]
            )
        )

    def test_repeated_offline_audio_mismatch_fails_strict(self) -> None:
        report = production_report()
        report["firstInitial"]["values"]["audio_repeat"] = "audio-random"
        report["firstRepeat"]["values"]["audio_repeat"] = "audio-random"

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The profile A, first capture audio value disagrees with audio_repeat.",
            summary["productionIssues"],
        )

    def test_legacy_schema_fails_strict_but_not_public_alpha(self) -> None:
        report = production_report()
        del report["auditSchemaVersion"]

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertEqual(summary["auditSchemaVersion"], 1)
        self.assertIn(
            "The report does not use the current strict fingerprint audit schema.",
            summary["productionIssues"],
        )

    def test_previous_schema_five_cannot_use_schema_six_production_contract(self) -> None:
        report = production_report()
        report["auditSchemaVersion"] = 5

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The report does not use the current strict fingerprint audit schema.",
            summary["productionIssues"],
        )

    def test_identity_catalog_drift_fails_strict_but_not_public_alpha(self) -> None:
        report = production_report()
        report["identityCatalogVersion"] = 2

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The report does not use the current immutable identity catalog.",
            summary["productionIssues"],
        )

    def test_proxied_host_candidate_fails_strict_but_not_public_alpha(
        self,
    ) -> None:
        report = production_report()
        report["second"]["values"]["network_route"] = "proxied"
        report["second"]["values"]["webrtc_stun_requests"] = "0"
        report["second"]["values"]["webrtc_candidate_summary"] = (
            '{"total":1,"host":1,"srflx":0,"prflx":0,'
            '"relay":0,"unknown":0}'
        )

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["qualified"])
        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The profile B proxied route exposed a direct WebRTC candidate.",
            summary["productionIssues"],
        )

    def test_unknown_candidate_type_fails_strict(self) -> None:
        report = production_report()
        report["firstInitial"]["values"]["webrtc_candidate_summary"] = (
            '{"total":1,"host":0,"srflx":0,"prflx":0,'
            '"relay":0,"unknown":1}'
        )

        summary = MODULE.verification_summary(report)

        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The profile A, first capture WebRTC candidate summary contains "
            "unknown candidate types.",
            summary["productionIssues"],
        )

    def test_malformed_candidate_summary_fails_strict(self) -> None:
        invalid_summaries = (
            '{"total":1,"host":0,"srflx":0,"prflx":0,"relay":0}',
            '{"total":0,"host":-1,"srflx":0,"prflx":0,'
            '"relay":0,"unknown":1}',
            '{"total":257,"host":257,"srflx":0,"prflx":0,'
            '"relay":0,"unknown":0}',
            '{"total":2,"host":1,"srflx":0,"prflx":0,'
            '"relay":0,"unknown":0}',
            '{"total":0,"host":0,"srflx":0,"prflx":0,'
            '"relay":0,"unknown":0,"address":"192.0.2.1"}',
        )

        for candidate_summary in invalid_summaries:
            with self.subTest(candidate_summary=candidate_summary):
                report = production_report()
                report["firstInitial"]["values"][
                    "webrtc_candidate_summary"
                ] = candidate_summary

                summary = MODULE.verification_summary(report)

                self.assertFalse(summary["productionQualified"])
                self.assertIn(
                    "The profile A, first capture WebRTC candidate summary is "
                    "invalid.",
                    summary["productionIssues"],
                )

    def test_invalid_webrtc_route_probe_or_completion_fails_strict(
        self,
    ) -> None:
        mutations = (
            (
                "network_route",
                "unknown",
                "configured network route is invalid",
            ),
            ("webrtc_probe", "external-stun", "probe contract is invalid"),
            (
                "webrtc_complete",
                "false",
                "WebRTC gathering did not complete",
            ),
        )
        for key, value, expected in mutations:
            with self.subTest(key=key):
                report = production_report()
                report["firstInitial"]["values"][key] = value
                summary = MODULE.verification_summary(report)
                self.assertFalse(summary["productionQualified"])
                self.assertTrue(
                    any(
                        expected in issue
                        for issue in summary["productionIssues"]
                    )
                )

    def test_proxied_relay_only_candidate_is_accepted(self) -> None:
        report = production_report()
        report["second"]["values"]["network_route"] = "proxied"
        report["second"]["values"]["webrtc_stun_requests"] = "0"
        report["second"]["values"]["webrtc_candidate_summary"] = (
            '{"total":1,"host":0,"srflx":0,"prflx":0,'
            '"relay":1,"unknown":0}'
        )

        summary = MODULE.verification_summary(report)

        self.assertTrue(summary["productionQualified"])
        self.assertFalse(summary["effectiveHTTPRouteObserved"])
        self.assertEqual(
            summary["networkEvidenceScope"],
            "configured-route-webrtc-only",
        )

    def test_configured_route_alias_is_rejected_as_ambiguous_input(self) -> None:
        for keep_legacy_key in (False, True):
            with self.subTest(keep_legacy_key=keep_legacy_key):
                report = production_report()
                values = report["firstInitial"]["values"]
                values["configured_route"] = "direct"
                if not keep_legacy_key:
                    del values["network_route"]

                issues = MODULE.exact_schema_issues(report)

                self.assertTrue(
                    any(
                        "unsupported fields: configured_route" in issue
                        for issue in issues
                    )
                )

    def test_missing_direct_control_fails_strict(self) -> None:
        report = production_report()
        del report["webrtcDirectControl"]

        summary = MODULE.verification_summary(report)

        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The report does not contain a WebRTC direct positive control.",
            summary["productionIssues"],
        )

    def test_proxied_stun_request_fails_strict(self) -> None:
        report = production_report()
        report["second"]["values"]["network_route"] = "proxied"
        report["second"]["values"]["webrtc_stun_requests"] = "1"

        summary = MODULE.verification_summary(report)

        self.assertFalse(summary["productionQualified"])
        self.assertIn(
            "The profile B proxied route sent a loopback STUN request.",
            summary["productionIssues"],
        )

    def test_load_report_rejects_non_object_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_text("[]", encoding="utf-8")
            with self.assertRaisesRegex(MODULE.FingerprintReportError, "JSON object"):
                MODULE.load_report(path)

    def test_rejects_extra_sensitive_capture_value(self) -> None:
        report = production_report()
        report["firstInitial"]["values"]["proxyPassword"] = "secret"

        summary = MODULE.verification_summary(report)

        self.assertFalse(summary["qualified"])
        self.assertIn(
            "The firstInitial values contain unsupported fields: proxyPassword.",
            summary["issues"],
        )

    def test_rejects_extra_top_level_key(self) -> None:
        report = production_report()
        report["cookies"] = "secret"

        summary = MODULE.verification_summary(report)

        self.assertFalse(summary["qualified"])
        self.assertIn(
            "The report contains unsupported top-level fields: cookies.",
            summary["issues"],
        )

    def test_rejects_extra_capture_key(self) -> None:
        report = production_report()
        report["firstInitial"]["visitedURL"] = "https://example.test/private"

        summary = MODULE.verification_summary(report)

        self.assertFalse(summary["qualified"])
        self.assertIn(
            "The firstInitial capture contains unsupported fields: visitedURL.",
            summary["issues"],
        )


def production_report(*, runtime_version: str = "144.0.7559.132") -> dict:
    return {
        "id": "BC70AD3E-19E0-4E73-BA04-B5B7EAC739B9",
        "createdAt": "2026-07-25T08:29:41Z",
        "managerVersion": "0.3.12",
        "managerBuild": "15",
        "auditSchemaVersion": 7,
        "identityCatalogVersion": 1,
        "executionMode": "browser",
        "runtimeName": "NeAntik Browser",
        "runtimeVersion": runtime_version,
        "runtimeFlavor": "fingerprintChromium",
        "runtimeCodeSignatureValid": True,
        "runtimeExecutableSHA256": SHA_A,
        "runtimeFrameworkSHA256": SHA_B,
        "webrtcDirectControl": capture(
            profile_id="00000000-0000-4000-8000-000000000303",
            identity_code="NA-13579BDF",
            canvas="control",
            webgl_pixels="control",
            audio="control",
            client_rects="control",
            gpu="M2 Pro",
            cores=12,
            screen="1512x982x1512x957x24x2",
            platform_version="15.3.1",
            runtime_version=runtime_version,
        ),
        "firstInitial": capture(
            profile_id="CB226A31-C3F1-4CC9-A5B4-FA50D3C89747",
            identity_code="NA-13579BDF",
            canvas="canvas-a",
            webgl_pixels="webgl-a",
            audio="audio-a",
            client_rects="rects-a",
            gpu="M2 Pro",
            cores=12,
            screen="1512x982x1512x957x24x2",
            platform_version="15.3.1",
            runtime_version=runtime_version,
        ),
        "second": capture(
            profile_id="5AF8B3FB-03BE-4A7F-B5EC-3955D04ABB0E",
            identity_code="NA-2468ACE0",
            canvas="canvas-b",
            webgl_pixels="webgl-b",
            audio="audio-b",
            client_rects="rects-b",
            gpu="M4",
            cores=10,
            screen="1280x832x1280x807x24x2",
            platform_version="15.1.0",
            runtime_version=runtime_version,
        ),
        "firstRepeat": capture(
            profile_id="CB226A31-C3F1-4CC9-A5B4-FA50D3C89747",
            identity_code="NA-13579BDF",
            canvas="canvas-a",
            webgl_pixels="webgl-a",
            audio="audio-a",
            client_rects="rects-a",
            gpu="M2 Pro",
            cores=12,
            screen="1512x982x1512x957x24x2",
            platform_version="15.3.1",
            runtime_version=runtime_version,
        ),
    }


def write_integrated_app_fixture(root: Path) -> Path:
    integrated_app = root / "NeAntik.app"
    runtime_app = (
        integrated_app / "Contents/Resources/NeAntik Browser.app"
    )
    executable = runtime_app / "Contents/MacOS/NeAntik Browser"
    framework = (
        runtime_app
        / "Contents/Frameworks/NeVision Browser Framework.framework"
        / "Versions/144.0.7559.132/NeVision Browser Framework"
    )
    executable.parent.mkdir(parents=True)
    framework.parent.mkdir(parents=True)
    executable.write_bytes(b"runtime executable")
    framework.write_bytes(b"runtime framework")
    manager_info = integrated_app / "Contents/Info.plist"
    manager_info.parent.mkdir(parents=True, exist_ok=True)
    with manager_info.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleShortVersionString": "0.3.12",
                "CFBundleVersion": "15",
            },
            file,
        )
    runtime_info = runtime_app / "Contents/Info.plist"
    with runtime_info.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleExecutable": "NeAntik Browser",
                "CFBundleShortVersionString": "144.0.7559.132",
            },
            file,
        )
    evidence_root = (
        integrated_app
        / "Contents/Resources/NeAntikRuntimeEvidence"
    )
    evidence_root.mkdir(parents=True)
    patch_series = evidence_root / "neantik-patch-series.json"
    device_tuples = evidence_root / "apple-device-tuples.json"
    security_baseline = evidence_root / "security-baseline.json"
    source_contract = evidence_root / "chromium-150-source-contract.json"
    source_provenance = evidence_root / "source-provenance.json"
    args_gn = evidence_root / "args.gn"
    patch_series.write_text('{"schemaVersion":1}\n', encoding="utf-8")
    device_tuples.write_text(
        '{"schemaVersion":1,"tuples":[]}\n',
        encoding="utf-8",
    )
    security_baseline.write_text('{"schemaVersion":1}\n', encoding="utf-8")
    source_contract.write_text(
        '{"schemaVersion":1,"binaryBindingStatus":"pending-new-build"}\n',
        encoding="utf-8",
    )
    source_provenance.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "binaryBindingStatus": "pending-new-build",
                "contractSHA256": MODULE.sha256_file(source_contract),
            }
        ),
        encoding="utf-8",
    )
    args_gn.write_text(
        'target_cpu = "arm64"\nangle_enable_metal = true\n',
        encoding="utf-8",
    )
    fingerprint_patch_sha = "1" * 64
    mac_patch_sha = "2" * 64
    overlay_sha = "3" * 64
    tuple_overlay_sha = "4" * 64
    lock_path = evidence_root / "fingerprint-chromium.lock.json"
    lock_path.write_text(
        json.dumps(
            {
                "fingerprintChromium": {
                    "patchSeriesSHA256": fingerprint_patch_sha,
                },
                "macPackaging": {
                    "patchSeriesSHA256": mac_patch_sha,
                },
                "nevisionOverlay": {
                    "scriptSHA256": overlay_sha,
                },
                "nevisionDeviceTuples": {
                    "scriptSHA256": tuple_overlay_sha,
                },
            }
        ),
        encoding="utf-8",
    )
    evidence_path = evidence_root / "runtime-verification.json"
    evidence_path.write_text(
        json.dumps(
            {
                "schemaVersion": 3,
                "createdAt": "2026-07-25T08:00:00Z",
                "chromiumVersion": "144.0.7559.132",
                "sourceLockSHA256": MODULE.sha256_file(lock_path),
                "candidateLockSHA256": MODULE.sha256_file(lock_path),
                "sourceContractSHA256":
                    MODULE.sha256_file(source_contract),
                "sourceProvenanceSHA256":
                    MODULE.sha256_file(source_provenance),
                "fingerprintChromiumPatchSeriesSHA256":
                    fingerprint_patch_sha,
                "macPackagingPatchSeriesSHA256": mac_patch_sha,
                "neantikPatchManifestSHA256":
                    MODULE.sha256_file(patch_series),
                "appleDeviceTuplesManifestSHA256":
                    MODULE.sha256_file(device_tuples),
                "securityBaselineSHA256":
                    MODULE.sha256_file(security_baseline),
                "nevisionOverlaySHA256": overlay_sha,
                "nevisionDeviceTupleOverlaySHA256":
                    tuple_overlay_sha,
                "buildArguments": {
                    "sha256": MODULE.sha256_file(args_gn),
                },
                "executable": {
                    "path": "Contents/MacOS/NeAntik Browser",
                    "sha256": MODULE.sha256_file(executable),
                },
                "framework": {
                    "path": (
                        "Contents/Frameworks/"
                        "NeVision Browser Framework.framework/Versions/"
                        "144.0.7559.132/NeVision Browser Framework"
                    ),
                    "sha256": MODULE.sha256_file(framework),
                },
            }
        ),
        encoding="utf-8",
    )
    return integrated_app


def capture(
    *,
    profile_id: str,
    identity_code: str,
    canvas: str,
    webgl_pixels: str,
    audio: str,
    client_rects: str,
    gpu: str,
    cores: int,
    screen: str,
    platform_version: str,
    runtime_version: str = "144.0.7559.132",
) -> dict:
    client_hints = (
        '{"architecture":"arm","bitness":"64","platform":"macOS",'
        f'"platformVersion":"{platform_version}","uaFullVersion":"{runtime_version}"}}'
    )
    user_agent = f"Mozilla/5.0 Chrome/{runtime_version} Safari/537.36"
    renderer = (
        "ANGLE (Apple, ANGLE Metal Renderer: "
        f"Apple {gpu}, Unspecified Version)"
    )
    return {
        "capturedAt": "2026-07-25T08:29:38Z",
        "profileID": profile_id,
        "profileName": identity_code,
        "identityCode": identity_code,
        "values": {
            "canvas": canvas,
            "canvas_repeat": canvas,
            "webgl_pixels": webgl_pixels,
            "webgl_pixels_repeat": webgl_pixels,
            "audio": audio,
            "audio_repeat": audio,
            "client_rects": client_rects,
            "client_rects_repeat": client_rects,
            "webgl_vendor": "Google Inc. (Apple)",
            "webgl_renderer": renderer,
            "webgl_extensions": "extensions",
            "webgl_shader_precision": "precision",
            "webgpu_policy": "disabled",
            "user_agent": user_agent,
            "platform": "MacIntel",
            "client_hints": client_hints,
            "screen": screen,
            "css_screen_match": "width:1|height:1|resolution:1",
            "hardware_concurrency": str(cores),
            "device_memory": "8",
            "touch_points": "0",
            "fonts": "Arial,Menlo",
            "languages": "en-US,en",
            "timezone": "Asia/Bangkok",
            "intl_locale": "en-US",
            "primary_locale_core": "en-Latn-US",
            "intl_locale_core": "en-Latn-US",
            "worker_canvas": canvas,
            "worker_webgl_pixels": webgl_pixels,
            "worker_webgl_vendor": "Google Inc. (Apple)",
            "worker_webgl_renderer": renderer,
            "worker_webgl_extensions": "extensions",
            "worker_webgl_shader_precision": "precision",
            "worker_user_agent": user_agent,
            "worker_platform": "MacIntel",
            "worker_languages": "en-US,en",
            "worker_timezone": "Asia/Bangkok",
            "worker_intl_locale": "en-US",
            "worker_primary_locale_core": "en-Latn-US",
            "worker_intl_locale_core": "en-Latn-US",
            "worker_hardware_concurrency": str(cores),
            "worker_device_memory": "8",
            "worker_client_hints": client_hints,
            "network_route": "direct",
            "webrtc_probe": "loopback-stun-v1",
            "webrtc_complete": "true",
            "webrtc_stun_requests": "1",
            "webrtc_candidate_summary":
                '{"total":0,"host":0,"srflx":0,"prflx":0,'
                '"relay":0,"unknown":0}',
        },
    }


def write_runtime_lock_fixture(
    root: Path,
    *,
    runtime_created_at: str = "2026-07-25T08:29:00Z",
) -> Path:
    runtime_report = root / "artifacts" / "runtime-report.json"
    runtime_report.parent.mkdir(parents=True)
    runtime_report.write_text(
        (
            "{"
            '"chromiumVersion":"144.0.7559.132",'
            f'"createdAt":"{runtime_created_at}",'
            f'"executable":{{"sha256":"{SHA_A}"}},'
            f'"framework":{{"sha256":"{SHA_B}"}}'
            "}"
        ),
        encoding="utf-8",
    )
    lock = root / "runtime" / "fingerprint-chromium.lock.json"
    lock.parent.mkdir(parents=True)
    lock.write_text(
        (
            "{"
            '"fingerprintChromium":{"chromiumVersion":"144.0.7559.132"},'
            '"verification":{"runtimeReport":"artifacts/runtime-report.json"}'
            "}"
        ),
        encoding="utf-8",
    )
    return lock


if __name__ == "__main__":
    unittest.main()
