import importlib.util
import json
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SCRIPT = ROOT / "scripts/verify-packaged-runtime-report.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_packaged_runtime_report",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VerifyPackagedRuntimeReportTests(unittest.TestCase):
    def test_m15680_packaged_source_binding_and_tampering(self):
        import chromium_15680_release_evidence as e
        runtime = ROOT / "runtime"
        contract = e.verify_contract(ROOT)
        adoption = json.loads((runtime / e.ADOPTION).read_text())
        provenance = e._expected_provenance(contract, adoption,
                    {"buildEvidenceStatus": "verified", "dependencyGitCheckoutCount": 150}, ROOT)
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            (evidence / "source-provenance.json").write_text(json.dumps(provenance))
            lock = e.expected_lock(evidence / "source-provenance.json", ROOT)
            (evidence / "fingerprint-chromium.lock.json").write_text(json.dumps(lock))
            shutil.copy2(runtime / e.CONTRACT, evidence / e.CONTRACT)
            packaged = evidence / "chromium-15680-source-evidence"
            packaged.mkdir()
            names = ("chromium-15680-source-adoption-v1.json", "chromium-15680-deps-lock.json",
                     "chromium-15680-neantik.patch", "chromium-15680-devtools-typescript6.patch",
                     "chromium-15680-v8-scope-iterator-compat.patch", "chromium-15680-rebase-plan.json",
                     "chromium-15680-build-evidence.json", "chromium-15680-args.gn")
            for name in names:
                shutil.copy2(runtime / name, packaged / name)
            MODULE.verify_m15680_source_evidence(evidence, ROOT)
            (packaged / "chromium-15680-args.gn").write_text("altered\n")
            with self.assertRaisesRegex(MODULE.PackagedRuntimeReportError, "source evidence differs"):
                MODULE.verify_m15680_source_evidence(evidence, ROOT)
            shutil.copy2(runtime / "chromium-15680-args.gn", packaged / "chromium-15680-args.gn")
            lock["fingerprintChromium"]["chromiumVersion"] = "156.0.8078.74"
            (evidence / "fingerprint-chromium.lock.json").write_text(json.dumps(lock))
            with self.assertRaisesRegex(MODULE.PackagedRuntimeReportError, "source binding failed"):
                MODULE.verify_m15680_source_evidence(evidence, ROOT)

    def test_m15680_selects_its_own_packaged_source_paths(self):
        lock, contract = MODULE.source_evidence_paths("156.0.8078.80", Path("/evidence"), Path("/project"))
        self.assertEqual(lock, Path("/evidence/fingerprint-chromium.lock.json"))
        self.assertEqual(contract, Path("/evidence/chromium-15680-source-contract.json"))
        with self.assertRaises(MODULE.PackagedRuntimeReportError):
            MODULE.source_evidence_paths("156.0.8078.81", Path("/evidence"), Path("/project"))
    def test_m156_source_context_wiring_and_full_unsealed_fallback(self):
        from unittest.mock import patch
        import chromium_15612_source_context as contexts
        import chromium_15612_packaged_evidence as packaged
        import chromium_15612_variant as variant
        lock = {'sourceVariant': variant.FONT_VARIANT,
                'sourceContract': 'runtime/' + variant.FONT_PREFIX + '-source-contract.json',
                'sourceProvenance': 'runtime/' + variant.FONT_PREFIX + '-port-candidate.json'}
        for sealed in (False, True):
            marker = object() if sealed else None
            with self.subTest(sealed=sealed), patch.object(MODULE, 'load_json', return_value=lock), \
                 patch.object(contexts, 'verify_source_context', return_value=marker,
                              side_effect=None if sealed else contexts.SourceContextUnavailable('unsealed')), \
                 patch.object(packaged, 'process') as copied, \
                 patch.object(variant, 'verify_report_source_fields') as report, \
                 patch.object(variant, 'verify_signed_runtime_identity') as runtime:
                MODULE.verify_m156_source_and_runtime({}, Path('/app'), Path('/evidence'), Path('/project'))
                for gate in (copied, report, runtime):
                    gate.assert_called_once()
                    self.assertIs(gate.call_args.kwargs['source_context'], marker)

    def test_m156_source_validation_error_never_falls_back_to_a_cached_result(self):
        from unittest.mock import patch
        import chromium_15612_source_context as contexts
        import chromium_15612_packaged_evidence as packaged
        with patch.object(MODULE, 'load_json', return_value={}), \
             patch.object(contexts, 'verify_source_context', side_effect=ValueError('source failed')), \
             patch.object(packaged, 'process') as copied:
            with self.assertRaisesRegex(MODULE.PackagedRuntimeReportError, 'source failed'):
                MODULE.verify_m156_source_and_runtime({}, Path('/app'), Path('/evidence'), Path('/project'))
            copied.assert_not_called()

    def test_semantic_variant_uses_its_exact_lock_and_contract(self):
        prefix = "chromium-15540-semantic-v3"
        candidate = {"semanticCorrectionSet": "canvas-audio-webgl-native-webrtc-v3",
                     "sourceContract": "runtime/" + prefix + "-source-contract.json",
                     "sourceProvenance": "runtime/" + prefix + "-port-candidate.json"}
        lock, contract = MODULE.source_evidence_paths("155.0.8059.40", Path("/evidence"), Path("/project"), candidate)
        self.assertEqual(lock.name, "fingerprint-" + prefix + ".lock.json")
        self.assertEqual(contract.name, prefix + "-source-contract.json")
        for changes in ({"sourceContract": "runtime/chromium-15540-source-contract.json"},
                        {"semanticCorrectionSet": "unknown"}, {"semanticCorrectionSet": None}):
            with self.assertRaises(ValueError):
                MODULE.source_evidence_paths("155.0.8059.40", Path("/evidence"), Path("/project"), {**candidate, **changes})

    def test_historical_m154_diagnostic_candidate_stays_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence"
            project_root = root / "project"
            with self.assertRaisesRegex(
                MODULE.PackagedRuntimeReportError,
                "154.0.8037.58 is diagnostic-only",
            ):
                MODULE.source_evidence_paths(
                    "154.0.8037.58",
                    evidence,
                    project_root,
                )

    def test_m154_qualified_version_selects_exact_m154_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, contract = MODULE.source_evidence_paths(
                "154.0.8037.93",
                root / "evidence",
                root / "project",
            )
            self.assertEqual(
                lock,
                root / "project/runtime/fingerprint-chromium-154.lock.json",
            )
            self.assertEqual(
                contract,
                root / "evidence/chromium-154-source-contract.json",
            )

    def test_unreviewed_m154_patch_versions_stay_blocked(self) -> None:
        with self.assertRaisesRegex(
            MODULE.PackagedRuntimeReportError,
            "release qualification is unavailable",
        ):
            MODULE.source_evidence_paths(
                "154.0.8037.94",
                Path("/tmp/evidence"),
                Path("/tmp/project"),
            )

    def test_m15498_selects_new_lock_and_canonical_bundle_contract_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, contract = MODULE.source_evidence_paths(
                "154.0.8037.98", root / "evidence", root / "project"
            )
            self.assertEqual(
                lock, root / "project/runtime/fingerprint-chromium-15498.lock.json"
            )
            self.assertEqual(
                contract, root / "evidence/chromium-154-source-contract.json"
            )

    def test_m155_selects_exact_new_contract_and_rejects_unknown_version(self):
        lock, contract = MODULE.source_evidence_paths(
            "155.0.8059.40", Path("/evidence"), Path("/project"))
        self.assertEqual(lock.name, "fingerprint-chromium-15540.lock.json")
        self.assertEqual(contract.name, "chromium-15540-source-contract.json")
        for version in ("155.0.8059.26", "155.0.8059.41"):
            with self.assertRaises(MODULE.PackagedRuntimeReportError):
                MODULE.source_evidence_paths(version, Path("/evidence"), Path("/project"))

    def test_m153_uses_only_m153_lock_and_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, contract = MODULE.source_evidence_paths(
                "153.0.8010.52",
                root / "evidence",
                root / "project",
            )

            self.assertEqual(
                lock,
                root / "project/runtime/fingerprint-chromium-153.lock.json",
            )
            self.assertEqual(
                contract,
                root / "evidence/chromium-153-port-status.json",
            )

    def test_m152_uses_m152_lock_and_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, contract = MODULE.source_evidence_paths(
                "152.0.7977.64",
                root / "evidence",
                root / "project",
            )

            self.assertEqual(
                lock,
                root / "project/runtime/fingerprint-chromium.lock.json",
            )
            self.assertEqual(
                contract,
                root / "evidence/chromium-152-source-contract.json",
            )

    def test_unqualified_patch_level_cannot_reuse_m152_or_m153_evidence(self) -> None:
        for version in ("152.0.7977.65", "153.0.8010.53"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(
                    MODULE.PackagedRuntimeReportError,
                    "Unsupported Chromium runtime version",
                ):
                    MODULE.source_evidence_paths(
                        version,
                        Path("/tmp/evidence"),
                        Path("/tmp/project"),
                    )

    def test_unknown_runtime_version_fails_closed(self) -> None:
        with self.assertRaisesRegex(
            MODULE.PackagedRuntimeReportError,
            "Unsupported Chromium runtime version",
        ):
            MODULE.source_evidence_paths(
                "151.0.7922.75",
                Path("/tmp/evidence"),
                Path("/tmp/project"),
            )

    def make_runtime(self, root: Path) -> tuple[Path, dict[str, object]]:
        runtime = root / "NeAntik Browser.app"
        contents = runtime / "Contents"
        macos = contents / "MacOS"
        frameworks = contents / "Frameworks/Browser.framework/Versions/1"
        macos.mkdir(parents=True)
        frameworks.mkdir(parents=True)
        info = {
            "CFBundleExecutable": "NeAntik Browser",
            "CFBundleShortVersionString": "151.0.7922.75",
        }
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        (macos / "NeAntik Browser").write_bytes(b"real executable")
        framework = frameworks / "NeAntik Browser Framework"
        framework.write_bytes(b"real framework")
        report: dict[str, object] = {
            "executable": {
                "path": "Contents/MacOS/NeAntik Browser",
            },
            "framework": {
                "path": str(framework.relative_to(runtime)),
            },
        }
        return runtime, report

    def test_canonical_bundle_path_rejects_escape(self) -> None:
        with self.assertRaisesRegex(
            MODULE.PackagedRuntimeReportError,
            "not canonical",
        ):
            MODULE.canonical_bundle_file(
                Path("/tmp/NeAntik Browser.app"),
                "Contents/MacOS/../../outside",
                "Contents/MacOS/",
            )

    def test_gpu_mode_requires_one_explicit_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "args.gn"
            path.write_text(
                "angle_enable_metal = true\nangle_enable_metal = false\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.PackagedRuntimeReportError,
                "exactly one Metal mode",
            ):
                MODULE.gpu_mode(path)

    def test_report_cannot_bind_alternate_in_prefix_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            runtime, report = self.make_runtime(Path(temporary))
            alternate = runtime / "Contents/MacOS/alternate"
            alternate.write_bytes(b"alternate")
            report["executable"] = {
                "path": "Contents/MacOS/alternate",
            }

            with self.assertRaisesRegex(
                MODULE.PackagedRuntimeReportError,
                "does not match CFBundleExecutable",
            ):
                MODULE.canonical_runtime_binaries(runtime, report)

    def test_report_cannot_bind_alternate_in_prefix_framework(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            runtime, report = self.make_runtime(Path(temporary))
            alternate = runtime / "Contents/Frameworks/alternate"
            alternate.write_bytes(b"alternate")
            report["framework"] = {
                "path": "Contents/Frameworks/alternate",
            }

            with self.assertRaisesRegex(
                MODULE.PackagedRuntimeReportError,
                "does not match the canonical Framework",
            ):
                MODULE.canonical_runtime_binaries(runtime, report)

    def test_integrated_verifier_uses_packaged_evidence_mode(self) -> None:
        text = (
            ROOT / "scripts/verify-integrated-release.sh"
        ).read_text(encoding="utf-8")
        runtime_call = (
            '"$PROJECT_DIR/scripts/verify-built-runtime.sh" \\\n'
            '  "$RUNTIME_APP"'
        )

        self.assertIn(runtime_call, text)
        self.assertIn("verify-packaged-runtime-report.py", text)
        self.assertNotIn('REPORT="$(mktemp', text)
        self.assertNotIn('"$RUNTIME_APP" \\\n  "$REPORT"', text)
        self.assertNotIn("verify-runtime-report-consistency.py", text)

    def test_integrated_verifier_rejects_unknown_runtime_major(self) -> None:
        text = (
            ROOT / "scripts/verify-integrated-release.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('elif [[ "$EXPECTED_RUNTIME_VERSION" == 152.* ]]', text)
        self.assertIn(
            "Unsupported Chromium runtime version for integrated release verification",
            text,
        )

    def test_integrated_verifier_has_exact_chromium_15680_evidence_route(self) -> None:
        text = (ROOT / "scripts/verify-integrated-release.sh").read_text(encoding="utf-8")

        self.assertIn('[[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.80" ]]', text)
        self.assertIn('chromium-15680-source-contract.json', text)
        self.assertIn('chromium-15680-source-evidence', text)
        self.assertIn('"$EXPECTED_RUNTIME_VERSION" == "156.0.8078.80"', text)
        self.assertIn('NeAntikEngineScope', text)
        self.assertIn('WebKit.framework', text)
        self.assertIn('Chromium-only candidate contains a WebKit host or framework', text)


if __name__ == "__main__":
    unittest.main()
