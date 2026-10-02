from __future__ import annotations

import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "export-chromium-154-port-input-manifest.py"
)
SPEC = importlib.util.spec_from_file_location("chromium154_port_manifest", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class ExportChromium154PortInputManifestTests(unittest.TestCase):
    def test_gn_lock_accepts_expected_values_and_rejects_drift(self) -> None:
        module.require_gn_value(
            'target_cpu = "arm64"\nangle_enable_metal=true\n', "target_cpu", "arm64"
        )
        with self.assertRaisesRegex(module.ManifestError, "safe_browsing_mode"):
            module.require_gn_value("safe_browsing_mode=1\n", "safe_browsing_mode", "0")
        with self.assertRaisesRegex(module.ManifestError, "dawn_enable_metal"):
            module.require_gn_value("angle_enable_metal=true\n", "dawn_enable_metal", "true")

    def test_malformed_chromium_version_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            version = Path(directory) / "VERSION"
            version.write_text("MAJOR=154\nMINOR=0\nBUILD=8037\n", encoding="utf-8")
            with self.assertRaisesRegex(module.ManifestError, "PATCH"):
                module.version_from_file(version)

    def test_args_gn_outside_locked_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "chrome").mkdir()
            args_gn = root / "args.gn"
            args_gn.write_text('target_cpu="arm64"\n', encoding="utf-8")
            with self.assertRaisesRegex(module.ManifestError, "out/<config>"):
                module.build_manifest(root, args_gn)

    def test_candidate_bundle_must_be_bound_to_source_out_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / "out" / "Release" / "NeAntik Browser.app"
            candidate.mkdir(parents=True)
            self.assertEqual(
                module.require_output_path(candidate, root, "binary app", ".app"),
                candidate.resolve(),
            )
            with self.assertRaisesRegex(module.ManifestError, "out/<config>"):
                module.require_output_path(root, root, "binary app", ".app")

    def test_source_commit_tree_and_version_are_locked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "chrome").mkdir()
            (root / "chrome" / "VERSION").write_text(
                "MAJOR=154\nMINOR=0\nBUILD=8037\nPATCH=93\n", encoding="utf-8"
            )
            args_gn = root / "out" / "Gen" / "args.gn"
            args_gn.parent.mkdir(parents=True)
            args_gn.write_text(
                'target_cpu = "arm64"\n'
                "angle_enable_metal=true\n"
                "dawn_enable_metal=true\n"
                "safe_browsing_mode=0\n"
                "enterprise_cloud_content_analysis=true\n",
                encoding="utf-8",
            )
            with patch.object(module, "load_common_exporter") as load_common:
                common = load_common.return_value
                common.git.side_effect = [
                    module.EXPECTED_COMMIT,
                    "0" * 40,
                ]
                with self.assertRaisesRegex(
                    module.ManifestError, "source lock mismatch"
                ):
                    module.build_manifest(root, args_gn)

    def test_build_manifest_binds_toolchain_inputs_but_is_never_release_ready(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "chrome").mkdir()
            (root / "chrome" / "VERSION").write_text(
                "MAJOR=154\nMINOR=0\nBUILD=8037\nPATCH=93\n", encoding="utf-8"
            )
            args_gn = root / "out" / "Diagnostic" / "args.gn"
            args_gn.parent.mkdir(parents=True)
            args_gn.write_text(
                'target_cpu = "arm64"\n'
                "angle_enable_metal=true\n"
                "dawn_enable_metal=true\n"
                "safe_browsing_mode=0\n"
                "enterprise_cloud_content_analysis=true\n",
                encoding="utf-8",
            )
            common = module.load_common_exporter()
            toolchain_inputs = {"releaseQualified": False, "fixture": "locked"}
            with (
                patch.object(module, "load_common_exporter", return_value=common),
                patch.object(
                    common,
                    "git",
                    side_effect=[module.EXPECTED_COMMIT, module.EXPECTED_TREE],
                ),
                patch.object(module, "find_patch_artifacts", return_value=[]),
                patch.object(module, "port_inputs", return_value={}),
                patch.object(
                    common,
                    "build_manifest",
                    return_value={"git": {"commit": module.EXPECTED_COMMIT}},
                ),
                patch.object(
                    module,
                    "source_toolchain_inputs",
                    return_value=toolchain_inputs,
                ),
            ):
                manifest = module.build_manifest(root, args_gn)

        self.assertEqual(manifest["sourceToolchainInputs"], toolchain_inputs)
        exporters = manifest["manifestExporters"]
        self.assertEqual(
            exporters["chromium154"]["sha256"],
            hashlib.sha256(SCRIPT_PATH.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            exporters["shared"]["sha256"],
            hashlib.sha256(module.COMMON_EXPORTER_PATH.read_bytes()).hexdigest(),
        )
        self.assertEqual(manifest["safeBrowsingMode"], 0)
        self.assertFalse(manifest["releaseReady"])

    def test_port_experiment_checks_every_patch_digest(self) -> None:
        common = module.load_common_exporter()
        experiment = json.loads(module.PORT_EXPERIMENT_PATH.read_text(encoding="utf-8"))
        apply_check = experiment["ownedPatchApplyCheck"]
        group_count = len(apply_check["groups"])
        self.assertEqual(apply_check["failed"], 0)
        self.assertGreater(group_count, 0)
        self.assertEqual(
            apply_check["applied"] + apply_check["preSatisfied"] + apply_check["pending"],
            group_count,
        )
        latest = apply_check["latestOrderedAttempt"]
        self.assertEqual(latest["orderedGroupCount"], group_count)
        self.assertFalse(latest["releaseQualified"])
        self.assertEqual(apply_check["failed"], 0)
        self.assertEqual(
            apply_check["applied"],
            sum(group["sequentialApplyCheck"] == "passed" for group in apply_check["groups"]),
        )
        self.assertEqual(
            apply_check["preSatisfied"],
            sum(
                group["sequentialApplyCheck"] == "already-satisfied-by-common-overlay"
                for group in apply_check["groups"]
            ),
        )
        for group in apply_check["groups"]:
            patch_path = module.PORT_EXPERIMENT_PATH.parent / group["patchFile"]
            self.assertEqual(
                hashlib.sha256(patch_path.read_bytes()).hexdigest(), group["sha256"]
            )
        if apply_check["pending"]:
            self.assertIsNone(latest["wholeTreePostimageManifestPath"])
            self.assertIsNone(latest["orderedReplayContinuationLogPath"])
            with self.assertRaisesRegex(
                module.ManifestError, "apply checks are incomplete"
            ):
                module.port_inputs(common)
        else:
            # This repository-data test checks every patch above. Full replay
            # validation uses temporary evidence in the dedicated tests below;
            # historical machine-local /tmp evidence is not a test fixture.
            self.assertEqual(latest["appliedGroupCount"], group_count)

    def test_upstream_m154_macos_series_inputs_are_pinned_and_hashed(self) -> None:
        common = module.load_common_exporter()
        experiment = json.loads(module.PORT_EXPERIMENT_PATH.read_text(encoding="utf-8"))

        inputs = module.upstream_macos_patch_inputs(common, experiment)

        self.assertEqual(inputs["tag"], "154.0.8037.57-1.1")
        self.assertEqual(inputs["commit"], "3241dc9cacee393621d277ec936376072f0cb3c5")
        self.assertEqual(inputs["tree"], "ef5ef849ed78edb7d8c07773df6bbb6753efe9ea")
        self.assertEqual(inputs["series"]["patchCount"], 20)
        self.assertEqual(len(inputs["patches"]), 20)
        self.assertFalse(inputs["releaseReady"])

    def test_upstream_m154_macos_series_hash_drift_fails_closed(self) -> None:
        common = module.load_common_exporter()
        experiment = json.loads(module.PORT_EXPERIMENT_PATH.read_text(encoding="utf-8"))
        experiment["upstreamMacPackagingCurrent"]["seriesSHA256"] = "0" * 64

        with self.assertRaisesRegex(module.ManifestError, "inconsistent"):
            module.upstream_macos_patch_inputs(common, experiment)

    def test_complete_clean_ordered_replay_allows_patch_inputs(self) -> None:
        common = module.load_common_exporter()
        experiment = json.loads(module.PORT_EXPERIMENT_PATH.read_text(encoding="utf-8"))
        latest = experiment["ownedPatchApplyCheck"]["latestOrderedAttempt"]
        group_count = len(experiment["ownedPatchApplyCheck"]["groups"])
        for group in experiment["ownedPatchApplyCheck"]["groups"]:
            # This fixture explicitly models the post-replay state; the checked
            # in experiment remains pending until a fresh clean replay passes.
            group["sequentialApplyCheck"] = "passed"
        experiment["ownedPatchApplyCheck"]["applied"] = group_count
        experiment["ownedPatchApplyCheck"]["preSatisfied"] = 0
        experiment["ownedPatchApplyCheck"]["pending"] = 0
        latest["orderedGroupCount"] = group_count
        latest["appliedGroupCount"] = group_count
        latest["rejectedArtifactCount"] = 0
        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "postimage.jsonl"
            continuation_path = Path(directory) / "continuation.log"
            continuation_path.write_text("fixture replay continuation\n", encoding="utf-8")
            latest.update(
                {
                    "dependencyRevisionMapSHA256": "d" * 64,
                    "pruningListSHA256": "e" * 64,
                    "presentPruningListSHA256": "f" * 64,
                    "pruneMode": "keep-contingent-paths",
                    "commonApplyLogSHA256": "a" * 64,
                }
            )
            header = {
                "record": "header",
                "schema": "neantik-chromium-source-tree-v1",
                "chromiumCommit": module.EXPECTED_COMMIT,
                "chromiumTree": module.EXPECTED_TREE,
                "chromiumVersion": module.EXPECTED_VERSION,
                "ownedGroupCount": group_count,
                "dependencyRevisionMapSHA256": "d" * 64,
                "pruningListSHA256": "e" * 64,
                "presentPruningListSHA256": "f" * 64,
                "pruneMode": "keep-contingent-paths",
                "commonSeriesSHA256": experiment["upstreamCommonOverlay"]["seriesSHA256"],
                "commonApplyLogSHA256": "a" * 64,
            }
            entry = {"record": "file", "path": "fixture", "sha256": "b" * 64}
            summary = {"record": "summary", "entries": 1}
            lines = [json.dumps(item) for item in (header, entry, summary)]
            manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            latest.update(
                {
                    "dependencyRevisionMapSHA256": "d" * 64,
                    "pruningListSHA256": "e" * 64,
                    "presentPruningListSHA256": "f" * 64,
                    "pruneMode": "keep-contingent-paths",
                    "commonApplyLogSHA256": "a" * 64,
                    "wholeTreePostimageManifestPath": str(manifest_path),
                    "wholeTreePostimageManifestSHA256": hashlib.sha256(
                        manifest_path.read_bytes()
                    ).hexdigest(),
                    "orderedReplayContinuationLogPath": str(continuation_path),
                    "orderedReplayContinuationLogSHA256": hashlib.sha256(
                        continuation_path.read_bytes()
                    ).hexdigest(),
                }
            )
            with patch.object(
                module.json,
                "loads",
                side_effect=[experiment, header, entry, summary],
            ):
                inputs = module.port_inputs(common)
        self.assertEqual(len(inputs["ownedPatches"]), group_count)
        self.assertEqual(
            inputs["portExperiment"]["status"], "diagnostic-not-release-ready"
        )

    def test_failed_sequential_patch_check_blocks_manifest_inputs(self) -> None:
        common = module.load_common_exporter()
        experiment = json.loads(module.PORT_EXPERIMENT_PATH.read_text(encoding="utf-8"))
        experiment["ownedPatchApplyCheck"]["failed"] = 1
        with patch.object(module.json, "loads", return_value=experiment):
            with self.assertRaisesRegex(
                module.ManifestError, "apply checks are incomplete or failed"
            ):
                module.port_inputs(common)

    def test_source_toolchain_inputs_bind_pinned_deps_without_qualifying_release(
        self,
    ) -> None:
        rust_text = (
            "objectName=rust-toolchain-m154.tar.xz\n"
            "sha256=abc123\n"
            "sizeBytes=4096\n"
        )
        dawn_text = "depsVersion: version:3@1.26.6\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dawn_deps = root / "third_party" / "dawn" / "DEPS"
            dawn_deps.parent.mkdir(parents=True)
            (root / "DEPS").write_text(rust_text, encoding="utf-8")
            dawn_deps.write_text(dawn_text, encoding="utf-8")
            status_path = root / "diagnostic-status.json"

            def digest(value: str) -> str:
                return hashlib.sha256(value.encode("utf-8")).hexdigest()

            status = {
                "chromium154SourceToolchainEvidence": {
                    "source": {
                        "version": module.EXPECTED_VERSION,
                        "commit": module.EXPECTED_COMMIT,
                        "tree": module.EXPECTED_TREE,
                    },
                    "rust": {
                        "sourceFile": "DEPS",
                        "sourceFileSHA256": digest(rust_text),
                        "objectName": "rust-toolchain-m154.tar.xz",
                        "sha256": "abc123",
                        "sizeBytes": 4096,
                        "rustcRevision": "revision-m154",
                        "architecture": "arm64",
                    },
                    "dawnGo": {
                        "sourceFile": "third_party/dawn/DEPS",
                        "sourceFileSHA256": digest(dawn_text),
                        "package": "infra/3pp/tools/go/mac-arm64",
                        "depsVersion": "version:3@1.26.6",
                        "instanceId": "instance-m154",
                        "architecture": "arm64",
                    },
                    "releaseQualified": False,
                }
            }
            status_path.write_text(json.dumps(status), encoding="utf-8")

            with (
                patch.object(module, "DIAGNOSTIC_STATUS_PATH", status_path),
                patch.object(module, "PROJECT_ROOT", root),
            ):
                result = module.source_toolchain_inputs(
                    module.load_common_exporter(), root
                )
            self.assertEqual(result["rust"]["sha256"], "abc123")
            self.assertEqual(result["dawnGo"]["depsVersion"], "version:3@1.26.6")
            self.assertFalse(result["releaseQualified"])

            status["chromium154SourceToolchainEvidence"]["rust"][
                "sourceFileSHA256"
            ] = "0" * 64
            status_path.write_text(json.dumps(status), encoding="utf-8")
            with (
                patch.object(module, "DIAGNOSTIC_STATUS_PATH", status_path),
                patch.object(module, "PROJECT_ROOT", root),
            ):
                with self.assertRaisesRegex(
                    module.ManifestError, "source digest mismatch"
                ):
                    module.source_toolchain_inputs(module.load_common_exporter(), root)

    def test_all_untracked_patch_artifacts_are_reported(self) -> None:
        common = module.load_common_exporter()
        with patch.object(common, "git", return_value=b"one.rej\0two.orig\0clean.cc\0"):
            self.assertEqual(
                module.find_patch_artifacts(common, Path("/unused")),
                ["one.rej", "two.orig"],
            )


if __name__ == "__main__":
    unittest.main()
