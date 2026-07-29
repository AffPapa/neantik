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
            "The report was created before the pinned runtime verification report.",
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

        self.assertIn("Capture timestamps are not ordered as A → B → A.", issues)

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

    def test_load_report_rejects_non_object_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_text("[]", encoding="utf-8")
            with self.assertRaisesRegex(MODULE.FingerprintReportError, "JSON object"):
                MODULE.load_report(path)


def production_report(*, runtime_version: str = "144.0.7559.132") -> dict:
    return {
        "id": "BC70AD3E-19E0-4E73-BA04-B5B7EAC739B9",
        "createdAt": "2026-07-25T08:29:41Z",
        "managerVersion": "0.3.12",
        "managerBuild": "15",
        "auditSchemaVersion": 3,
        "identityCatalogVersion": 1,
        "executionMode": "browser",
        "runtimeName": "NeAntik Browser",
        "runtimeVersion": runtime_version,
        "runtimeFlavor": "fingerprintChromium",
        "runtimeCodeSignatureValid": True,
        "runtimeExecutableSHA256": SHA_A,
        "runtimeFrameworkSHA256": SHA_B,
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
            {"CFBundleShortVersionString": "144.0.7559.132"},
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
    args_gn = evidence_root / "args.gn"
    patch_series.write_text('{"schemaVersion":1}\n', encoding="utf-8")
    device_tuples.write_text(
        '{"schemaVersion":1,"tuples":[]}\n',
        encoding="utf-8",
    )
    security_baseline.write_text('{"schemaVersion":1}\n', encoding="utf-8")
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
                "schemaVersion": 2,
                "createdAt": "2026-07-25T08:00:00Z",
                "chromiumVersion": "144.0.7559.132",
                "sourceLockSHA256": MODULE.sha256_file(lock_path),
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
                    "path": "/tmp/args.gn",
                    "sha256": MODULE.sha256_file(args_gn),
                },
                "executable": {
                    "path": (
                        "/tmp/NeAntik Browser.app/Contents/MacOS/"
                        "NeAntik Browser"
                    ),
                    "sha256": MODULE.sha256_file(executable),
                },
                "framework": {
                    "path": (
                        "/tmp/NeAntik Browser.app/Contents/Frameworks/"
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
            "worker_hardware_concurrency": str(cores),
            "worker_client_hints": client_hints,
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
