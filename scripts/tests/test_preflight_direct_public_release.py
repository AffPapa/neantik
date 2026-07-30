import importlib.util
import base64
import json
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "preflight-direct-public-release.py"
SPEC = importlib.util.spec_from_file_location("preflight_direct_public_release", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

VERIFIER_TESTS = Path(__file__).resolve().parent / "test_verify_gui_fingerprint_report.py"
VERIFIER_SPEC = importlib.util.spec_from_file_location(
    "test_verify_gui_fingerprint_report",
    VERIFIER_TESTS,
)
assert VERIFIER_SPEC and VERIFIER_SPEC.loader
VERIFIER_FIXTURES = importlib.util.module_from_spec(VERIFIER_SPEC)
sys.modules[VERIFIER_SPEC.name] = VERIFIER_FIXTURES
VERIFIER_SPEC.loader.exec_module(VERIFIER_FIXTURES)


class DirectPublicReleasePreflightTests(unittest.TestCase):
    def test_current_project_blocks_without_external_release_inputs(self) -> None:
        results = MODULE.verify_direct_public_release_plan(
            project_root=Path(__file__).resolve().parents[2],
            integrated_app=Path(__file__).resolve().parents[2] / "dist" / "NeAntik-Integrated.app",
            runtime_app=Path(__file__).resolve().parents[2]
            / "dist"
            / "NeAntik-Integrated.app"
            / "Contents"
            / "Resources"
            / "NeAntik Browser.app",
            args_gn=Path(__file__).resolve().parents[2]
            / "dist"
            / "NeAntik-Integrated.app"
            / "Contents"
            / "Resources"
            / "NeAntikRuntimeEvidence"
            / "args.gn",
            gui_fingerprint_report=Path(__file__).resolve().parents[2]
            / "dist"
            / "fingerprint-audit.json",
            runtime_lock=Path(__file__).resolve().parents[2]
            / "runtime"
            / "fingerprint-chromium.lock.json",
            download_url="https://downloads.neantik.app/NeAntik-0.3.10-arm64-notarized.zip",
            env={},
        )

        blocked = {result.name for result in results if not result.passed}
        self.assertIn("Developer ID signing environment", blocked)
        self.assertIn("Notary profile environment", blocked)
        if not (
            Path(__file__).resolve().parents[2] / "dist" / "fingerprint-audit.json"
        ).is_file():
            self.assertIn("GUI fingerprint qualification", blocked)

    def test_accepts_complete_fixture_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated, runtime, args_gn, gui_report, runtime_lock = write_fixture_project(root)

            with mock.patch.object(
                MODULE.GUI_VERIFIER,
                "expected_runtime_evidence_from_app",
                return_value={
                    "managerVersion": "0.3.12",
                    "managerBuild": "15",
                    "runtimeVersion": "150.0.7871.186",
                    "runtimeExecutableSHA256": "a" * 64,
                    "runtimeFrameworkSHA256": "b" * 64,
                },
            ):
                results = MODULE.verify_direct_public_release_plan(
                    project_root=root,
                    integrated_app=integrated,
                    runtime_app=runtime,
                    args_gn=args_gn,
                    gui_fingerprint_report=gui_report,
                    runtime_lock=runtime_lock,
                    download_url="https://downloads.neantik.app/NeAntik-1.2.3-arm64-notarized.zip",
                    env={
                        "NEANTIK_SIGNING_IDENTITY": "Developer ID Application: Example (TEAMID)",
                        "NEANTIK_NOTARY_PROFILE": "nevision-notary",
                        "NEANTIK_RELEASE_CHANNEL": "public-alpha",
                    },
                )

        self.assertTrue(all(result.passed for result in results))
        archive_gate = next(
            result
            for result in results
            if result.name == "Expected notarized archive name/download URL"
        )
        self.assertIn("HTTPS URL basename matches", archive_gate.details)

    def test_production_channel_rejects_public_alpha_only_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated, runtime, args_gn, gui_report, runtime_lock = (
                write_fixture_project(root)
            )
            results = MODULE.verify_direct_public_release_plan(
                project_root=root,
                integrated_app=integrated,
                runtime_app=runtime,
                args_gn=args_gn,
                gui_fingerprint_report=gui_report,
                runtime_lock=runtime_lock,
                download_url=(
                    "https://downloads.neantik.app/"
                    "NeAntik-1.2.3-arm64-notarized.zip"
                ),
                release_channel="production",
                env={
                    "NEANTIK_SIGNING_IDENTITY":
                        "Developer ID Application: Example (TEAMID)",
                    "NEANTIK_NOTARY_PROFILE": "nevision-notary",
                },
            )
        blocked = {
            result.name: result.details
            for result in results
            if not result.passed
        }
        self.assertIn("GUI fingerprint qualification", blocked)
        self.assertIn(
            "authenticated GUI evidence",
            blocked["GUI fingerprint qualification"],
        )

    def test_rejects_no_metal_args_and_wrong_download_url(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated, runtime, args_gn, gui_report, runtime_lock = write_fixture_project(root)
            args_gn.write_text('angle_enable_metal = false\n', encoding="utf-8")

            results = MODULE.verify_direct_public_release_plan(
                project_root=root,
                integrated_app=integrated,
                runtime_app=runtime,
                args_gn=args_gn,
                gui_fingerprint_report=gui_report,
                runtime_lock=runtime_lock,
                download_url="https://downloads.neantik.app/NeAntik-latest.zip",
                env={
                    "NEANTIK_SIGNING_IDENTITY": "a" * 40,
                    "NEANTIK_NOTARY_PROFILE": "nevision-notary",
                },
            )

        blocked = {result.name: result.details for result in results if not result.passed}
        self.assertIn("Metal runtime arguments", blocked)
        self.assertIn("Expected notarized archive name/download URL", blocked)

    def test_rejects_runtime_app_version_mismatch_with_runtime_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated, runtime, args_gn, gui_report, runtime_lock = write_fixture_project(root)
            write_plist(
                runtime / "Contents" / "Info.plist",
                {
                    "CFBundleIdentifier": "app.neantik.runtime",
                    "CFBundleShortVersionString": "150.0.7871.187",
                    "NeAntikRuntimeFlavor": "fingerprint-chromium",
                    "NeAntikRuntimeBuildMode": "source-build",
                },
            )

            results = MODULE.verify_direct_public_release_plan(
                project_root=root,
                integrated_app=integrated,
                runtime_app=runtime,
                args_gn=args_gn,
                gui_fingerprint_report=gui_report,
                runtime_lock=runtime_lock,
                download_url="https://downloads.neantik.app/NeAntik-1.2.3-arm64-notarized.zip",
                env={
                    "NEANTIK_SIGNING_IDENTITY": "Developer ID Application: Example (TEAMID)",
                    "NEANTIK_NOTARY_PROFILE": "nevision-notary",
                },
            )

        blocked = {result.name: result.details for result in results if not result.passed}
        self.assertIn("Runtime app matches runtime lock", blocked)
        self.assertIn("does not match runtime lock", blocked["Runtime app matches runtime lock"])

    def test_rejects_schema_one_runtime_report_for_new_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated, runtime, args_gn, gui_report, runtime_lock = (
                write_fixture_project(root)
            )
            report_path = args_gn.parent / "runtime-verification.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["schemaVersion"] = 1
            report_path.write_text(json.dumps(report), encoding="utf-8")

            results = MODULE.verify_direct_public_release_plan(
                project_root=root,
                integrated_app=integrated,
                runtime_app=runtime,
                args_gn=args_gn,
                gui_fingerprint_report=gui_report,
                runtime_lock=runtime_lock,
                download_url=(
                    "https://downloads.neantik.app/"
                    "NeAntik-1.2.3-arm64-notarized.zip"
                ),
                env={
                    "NEANTIK_SIGNING_IDENTITY": "a" * 40,
                    "NEANTIK_NOTARY_PROFILE": "nevision-notary",
                },
            )

        blocked = {
            result.name: result.details
            for result in results
            if not result.passed
        }
        self.assertIn("Chromium 150 source provenance", blocked)
        self.assertIn("schema 3", blocked["Chromium 150 source provenance"])

    def test_rejects_missing_source_provenance_sha(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            integrated, runtime, args_gn, gui_report, runtime_lock = (
                write_fixture_project(root)
            )
            report_path = args_gn.parent / "runtime-verification.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report.pop("sourceProvenanceSHA256")
            report_path.write_text(json.dumps(report), encoding="utf-8")

            results = MODULE.verify_direct_public_release_plan(
                project_root=root,
                integrated_app=integrated,
                runtime_app=runtime,
                args_gn=args_gn,
                gui_fingerprint_report=gui_report,
                runtime_lock=runtime_lock,
                download_url=(
                    "https://downloads.neantik.app/"
                    "NeAntik-1.2.3-arm64-notarized.zip"
                ),
                env={
                    "NEANTIK_SIGNING_IDENTITY": "a" * 40,
                    "NEANTIK_NOTARY_PROFILE": "nevision-notary",
                },
            )

        blocked = {
            result.name: result.details
            for result in results
            if not result.passed
        }
        self.assertIn("Chromium 150 source provenance", blocked)
        self.assertIn(
            "not bound to embedded source provenance",
            blocked["Chromium 150 source provenance"],
        )

    def test_json_report_exposes_stable_direct_release_boundary(self) -> None:
        results = [
            MODULE.GateResult("Integrated Direct bundle", True, "ok"),
            MODULE.GateResult(
                "Developer ID signing environment",
                False,
                "NEANTIK_SIGNING_IDENTITY is missing",
            ),
        ]

        report = MODULE.results_to_json(
            results,
            download_url="https://downloads.neantik.app/NeAntik-1.2.3-arm64-notarized.zip",
        )

        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["channel"], "Direct")
        self.assertFalse(report["ready"])
        self.assertTrue(report["downloadURLProvided"])
        self.assertEqual(report["gateCount"], 2)
        self.assertEqual(report["blockedCount"], 1)
        self.assertEqual(report["passedGates"], ["Integrated Direct bundle"])
        self.assertEqual(
            report["blockedGates"],
            [
                {
                    "name": "Developer ID signing environment",
                    "details": "NEANTIK_SIGNING_IDENTITY is missing",
                }
            ],
        )
        self.assertEqual(report["gates"][1]["passed"], False)
        self.assertIn("does not sign", report["releaseBoundary"])
        self.assertIn("publish", report["releaseBoundary"])


def write_plist(path: Path, values: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as file:
        plistlib.dump(values, file)


def write_fixture_project(root: Path) -> tuple[Path, Path, Path, Path, Path]:
    write_plist(
        root / "Resources" / "Info.plist",
        {
            "CFBundleIdentifier": "app.neantik.desktop",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "7",
        },
    )
    baseline = root / "runtime" / "security-baseline.json"
    baseline.parent.mkdir(parents=True)
    baseline.write_text(
        json.dumps({"minimumPublicChromiumVersion": "150.0.7871.186"}),
        encoding="utf-8",
    )
    integrated = root / "dist" / "NeAntik-Integrated.app"
    write_plist(
        integrated / "Contents" / "Info.plist",
        {
            "CFBundleIdentifier": "app.neantik.desktop",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "7",
        },
    )
    runtime = integrated / "Contents" / "Resources" / "NeAntik Browser.app"
    write_plist(
        runtime / "Contents" / "Info.plist",
        {
            "CFBundleIdentifier": "app.neantik.runtime",
            "CFBundleExecutable": "NeAntik Browser",
            "CFBundleShortVersionString": "150.0.7871.186",
            "NeAntikRuntimeFlavor": "fingerprint-chromium",
            "NeAntikRuntimeBuildMode": "source-build",
        },
    )
    args_gn = integrated / "Contents" / "Resources" / "NeAntikRuntimeEvidence" / "args.gn"
    args_gn.parent.mkdir(parents=True)
    args_gn.write_text('target_cpu = "arm64"\nangle_enable_metal = true\n', encoding="utf-8")
    executable = runtime / "Contents" / "MacOS" / "NeAntik Browser"
    framework = (
        runtime
        / "Contents/Frameworks/NeVision Browser Framework.framework"
        / "Versions/150.0.7871.186/NeVision Browser Framework"
    )
    executable.parent.mkdir(parents=True)
    framework.parent.mkdir(parents=True)
    executable.write_bytes(b"runtime executable")
    framework.write_bytes(b"runtime framework")
    embedded_report = args_gn.parent / "runtime-verification.json"
    source_contract = root / "runtime" / "chromium-150-source-contract.json"
    source_contract.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "binaryBindingStatus": "pending-new-build",
                "targetChromiumVersion": "150.0.7871.186",
            }
        ),
        encoding="utf-8",
    )
    embedded_contract = args_gn.parent / "chromium-150-source-contract.json"
    embedded_contract.write_bytes(source_contract.read_bytes())
    source_provenance = args_gn.parent / "source-provenance.json"
    source_provenance.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "binaryBindingStatus": "pending-new-build",
                "contractSHA256": MODULE.sha256_file(source_contract),
                "targetChromiumVersion": "150.0.7871.186",
            }
        ),
        encoding="utf-8",
    )
    fingerprint_patch_sha = "1" * 64
    mac_patch_sha = "2" * 64
    overlay_sha = "3" * 64
    tuple_overlay_sha = "4" * 64
    embedded_lock = args_gn.parent / "fingerprint-chromium.lock.json"
    embedded_lock.write_text(
        json.dumps(
            {
                "schemaVersion": 4,
                "fingerprintChromium": {
                    "chromiumVersion": "150.0.7871.186",
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
                "sourceContractSHA256": MODULE.sha256_file(source_contract),
                "sourceProvenanceSHA256":
                    MODULE.sha256_file(source_provenance),
            }
        ),
        encoding="utf-8",
    )
    patch_manifest = args_gn.parent / "neantik-patch-series.json"
    device_manifest = args_gn.parent / "apple-device-tuples.json"
    embedded_baseline = args_gn.parent / "security-baseline.json"
    patch_manifest.write_text('{"schemaVersion":1}\n', encoding="utf-8")
    device_manifest.write_text(
        '{"schemaVersion":1,"tuples":[]}\n',
        encoding="utf-8",
    )
    embedded_baseline.write_text(
        '{"schemaVersion":1}\n',
        encoding="utf-8",
    )
    embedded_report.write_text(
        json.dumps(
            {
                "schemaVersion": 3,
                "chromiumVersion": "150.0.7871.186",
                "createdAt": "2026-07-25T08:29:00Z",
                "sourceContractSHA256": MODULE.sha256_file(source_contract),
                "sourceProvenanceSHA256": MODULE.sha256_file(source_provenance),
                "sourceLockSHA256": MODULE.sha256_file(embedded_lock),
                "candidateLockSHA256": MODULE.sha256_file(embedded_lock),
                "fingerprintChromiumPatchSeriesSHA256":
                    fingerprint_patch_sha,
                "macPackagingPatchSeriesSHA256": mac_patch_sha,
                "neantikPatchManifestSHA256":
                    MODULE.sha256_file(patch_manifest),
                "appleDeviceTuplesManifestSHA256":
                    MODULE.sha256_file(device_manifest),
                "securityBaselineSHA256":
                    MODULE.sha256_file(embedded_baseline),
                "nevisionOverlaySHA256": overlay_sha,
                "nevisionDeviceTupleOverlaySHA256":
                    tuple_overlay_sha,
                "buildArguments": {
                    "sha256": MODULE.sha256_file(args_gn),
                },
                "executable": {
                    "path": "Contents/MacOS/NeAntik Browser",
                    "sha256": MODULE.GUI_VERIFIER.sha256_file(executable),
                },
                "framework": {
                    "path": (
                        "Contents/Frameworks/"
                        "NeVision Browser Framework.framework/Versions/"
                        "150.0.7871.186/NeVision Browser Framework"
                    ),
                    "sha256": MODULE.GUI_VERIFIER.sha256_file(framework),
                },
            }
        ),
        encoding="utf-8",
    )
    gui_report = root / "dist" / "fingerprint-audit.json"
    schema8_fixture = json.loads(
        (
            Path(__file__).resolve().parent
            / "fixtures"
            / "fingerprint-evidence-schema8-swift.json"
        ).read_text(encoding="utf-8")
    )
    gui_report.write_bytes(
        base64.b64decode(
            schema8_fixture["envelopeBase64"],
            validate=True,
        )
    )
    (root / "dist" / "direct-candidate-manifest.json").write_bytes(
        base64.b64decode(
            schema8_fixture["manifestBase64"],
            validate=True,
        )
    )
    runtime_report = root / "artifacts" / "runtime-report.json"
    runtime_report.parent.mkdir(parents=True)
    runtime_report.write_text(
        json.dumps(
            {
                "chromiumVersion": "150.0.7871.186",
                "createdAt": "2026-07-25T08:29:00Z",
                "executable": {"sha256": VERIFIER_FIXTURES.SHA_A},
                "framework": {"sha256": VERIFIER_FIXTURES.SHA_B},
            }
        ),
        encoding="utf-8",
    )
    runtime_lock = root / "runtime" / "fingerprint-chromium.lock.json"
    runtime_lock.write_bytes(embedded_lock.read_bytes())
    return integrated, runtime, args_gn, gui_report, runtime_lock


if __name__ == "__main__":
    unittest.main()
