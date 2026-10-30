import importlib.util
import hashlib
import json
import plistlib
from unittest.mock import patch
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "package-owned-webkit-release.py"
SPEC = importlib.util.spec_from_file_location("package_owned_webkit_release", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OwnedWebKitReleaseContractTests(unittest.TestCase):
    def test_production_validation_rejects_inconsistent_recipe_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, build, source, offer = (root / name for name in ('app', 'build', 'source', 'offer'))
            for path in (app, build, source, offer):
                path.mkdir()
            (app / 'Contents').mkdir()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({}))
            (build / 'CMakeCache.txt').write_text(f'CMAKE_HOME_DIRECTORY:INTERNAL={source}\n')
            (offer / 'manifest.json').write_text(json.dumps({
                'webkitBuildRecipe': {'path': 'recipe.md', 'sha256': '0' * 64},
                'sourceOfferComponents': []}))
            with patch.object(MODULE, 'validate_manager_info'), \
                    patch.object(MODULE, 'verify_v434_webgpu_correction'), \
                    patch.object(MODULE, 'verify_v438_jsc_review'), \
                    patch.object(MODULE, 'verify_source_archive_identity'), \
                    patch.object(MODULE, 'sha256', return_value=MODULE.EXPECTED_PATCH_SHA256), \
                    patch.object(MODULE, 'source_offer_replacements', return_value={}), \
                    patch.object(MODULE, 'source_crosswalk_binding') as crosswalk:
                with self.assertRaisesRegex(MODULE.PackageError, 'recipe identity'):
                    MODULE.validate_inputs(app, build, source, 'identity', root / 'receipt', offer, 'a' * 64)
                crosswalk.assert_not_called()

    def test_webkit_packaging_requires_current_chromium_compliance_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            (app / "Contents/Resources").mkdir(parents=True)
            with self.assertRaisesRegex(
                    MODULE.PackageError, "not integrated with the current Chromium runtime lock"):
                MODULE.verify_chromium_compliance_prerequisite(app)

    def test_filtered_v382_receipt_uses_measured_outputs_not_path_only_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image_bytes = b"verified arm64 image bytes"
            image = root / "Framework/Versions/A/Framework"
            image.parent.mkdir(parents=True)
            image.write_bytes(image_bytes)
            receipt = {
                "build": {"requestedTargets": {"targets": [
                    {"path": "Framework/Versions/A/Framework"}
                ]}},
                "outputs": [{
                    "path": "Framework/Versions/A/Framework",
                    "bytes": len(image_bytes),
                    "sha256": hashlib.sha256(image_bytes).hexdigest(),
                    "architecture": "arm64",
                }],
            }
            with patch.object(MODULE.subprocess, "check_output", return_value="arm64"):
                MODULE.verify_build_outputs(root, receipt)

    def test_runtime_overlay_application_checks_preimage_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frameworks = root / "Frameworks"
            target = frameworks / "WebCore.framework/Versions/A/Resources/test.svg"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"upstream")
            overlay = root / "replacement.svg"
            overlay.write_bytes(b"licensed first-party replacement")
            before = MODULE.sha256(target)
            after = MODULE.sha256(overlay)

            applied = MODULE._apply_runtime_overlay_file(
                frameworks, overlay, Path("WebCore.framework/Versions/A/Resources/test.svg"),
                before, after, overlay.stat().st_size)
            self.assertFalse(applied["alreadyApplied"])
            self.assertEqual(MODULE.sha256(target), after)

            repeated = MODULE._apply_runtime_overlay_file(
                frameworks, overlay, Path("WebCore.framework/Versions/A/Resources/test.svg"),
                before, after, overlay.stat().st_size)
            self.assertTrue(repeated["alreadyApplied"])
            self.assertEqual(repeated["sha256"], after)

            target.write_bytes(b"unexpected third-party bytes")
            with self.assertRaisesRegex(MODULE.PackageError, "preimage mismatch"):
                MODULE._apply_runtime_overlay_file(
                    frameworks, overlay, Path("WebCore.framework/Versions/A/Resources/test.svg"),
                    before, after, overlay.stat().st_size)

    def setUp(self):
        self.info = {
            "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": str(MODULE.production_build_number()),
        }

    def test_accepts_only_versioned_production_manager_and_existing_signer(self):
        MODULE.validate_manager_info(self.info, MODULE.IDENTITY_SHA1)

    def test_rejects_development_bundle(self):
        info = {**self.info, "CFBundleIdentifier": "app.neantik.desktop.dev"}
        with self.assertRaisesRegex(MODULE.PackageError, "production manager"):
            MODULE.validate_manager_info(info, MODULE.IDENTITY_SHA1)

    def test_rejects_non_1_0_release(self):
        info = {**self.info, "CFBundleShortVersionString": "0.8.26"}
        with self.assertRaisesRegex(MODULE.PackageError, "1.0.0"):
            MODULE.validate_manager_info(info, MODULE.IDENTITY_SHA1)

    def test_rejects_old_or_malformed_build_number(self):
        for build in (str(MODULE.production_build_number() - 1), "not-a-build"):
            with self.subTest(build=build), self.assertRaises(MODULE.PackageError):
                MODULE.validate_manager_info({**self.info, "CFBundleVersion": build},
                                             MODULE.IDENTITY_SHA1)

    def test_rejects_qa_metadata(self):
        info = {**self.info, "NeAntikBackupQualificationRunID": "qa-only"}
        with self.assertRaisesRegex(MODULE.PackageError, "QA manager metadata"):
            MODULE.validate_manager_info(info, MODULE.IDENTITY_SHA1)
        for key, value in (("NeAntikQATrustScope", True),
                           ("NeAntikProductionDiagnosticEnabled", True),
                           ("NeAntikProductionDiagnosticDataRoot", "/private/tmp/neantik-production-diagnostic-test")):
            with self.subTest(key=key), self.assertRaisesRegex(MODULE.PackageError, "QA manager metadata"):
                MODULE.validate_manager_info({**self.info, key: value}, MODULE.IDENTITY_SHA1)

    def test_rejects_different_signing_identity(self):
        with self.assertRaisesRegex(MODULE.PackageError, "existing pinned Developer ID"):
            MODULE.validate_manager_info(self.info, "0" * 40)

    def test_loads_exact_v135_clean_relink_receipt(self):
        receipt = (MODULE.ROOT / "docs/evidence/neantik-v135-clean-relocated-v132-webkit-relink-20261026.json")
        self.assertEqual(MODULE.sha256(receipt), MODULE.V135_BUILD_RECEIPT_SHA256)
        parsed = MODULE.load_build_receipt(receipt)
        self.assertEqual(parsed["id"], "neantik-v135-clean-relocated-v132-webkit-relink-20261026")
        self.assertEqual({row["path"] for row in parsed["outputs"]}, MODULE.BUILD_TARGETS)
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / receipt.name
            changed.write_bytes(receipt.read_bytes() + b" ")
            with self.assertRaisesRegex(MODULE.PackageError, "receipt hash mismatch"):
                MODULE.load_build_receipt(changed)

    def test_selects_rebound_production_host_and_binds_its_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            system = Path(temporary) / "host-system"
            owned = Path(temporary) / "host-owned"
            system.write_bytes(b"system linked")
            owned.write_bytes(b"bundle linked")
            receipt = {
                "status": "built-production-mode-unqualified",
                "qaProxy": False,
                "productionProxy": True,
                "binary": str(system),
                "binarySHA256": MODULE.sha256(system),
                "ownedBinary": str(owned),
                "ownedSHA256": MODULE.sha256(owned),
            }
            self.assertEqual(MODULE.production_host_binary(receipt), owned)
            receipt["ownedSHA256"] = "0" * 64
            with self.assertRaisesRegex(MODULE.PackageError, "changed"):
                MODULE.production_host_binary(receipt)

    def test_rejects_private_diagnostic_host_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            diagnostic = Path(temporary) / "host-diagnostic"
            diagnostic.write_bytes(b"private diagnostic host")
            receipt = {
                "status": "built-private-diagnostic",
                "qaProxy": False,
                "diagnosticProxy": True,
                "productionProxy": False,
                "ownedBinary": str(diagnostic),
                "ownedSHA256": MODULE.sha256(diagnostic),
            }
            with self.assertRaisesRegex(MODULE.PackageError, "production-only feature gate"):
                MODULE.production_host_binary(receipt)

    def test_source_archive_identity_does_not_require_local_git_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "WebKit.tar.zst"
            receipt = Path(temporary) / "recovery.json"
            payload = b"verified source archive fixture"
            archive.write_bytes(payload)
            receipt.write_text(json.dumps({
                "status": "exact-source-commit-recovered-and-patched;offer-incomplete",
                "repository": "https://github.com/WebKit/WebKit",
                "commit": MODULE.EXPECTED_COMMIT,
                "tree": MODULE.SOURCE_TREE,
                "sourceArchiveBytes": len(payload),
                "sourceArchiveSHA256": hashlib.sha256(payload).hexdigest(),
                "patchSHA256": MODULE.EXPECTED_PATCH_SHA256,
            }))
            with patch.object(MODULE, "SOURCE_ARCHIVE", archive), \
                    patch.object(MODULE, "SOURCE_RECOVERY", receipt), \
                    patch.object(MODULE, "SOURCE_ARCHIVE_SHA256", hashlib.sha256(payload).hexdigest()):
                MODULE.verify_source_archive_identity()

    def test_rejects_source_archive_receipt_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "WebKit.tar.zst"
            receipt = Path(temporary) / "recovery.json"
            archive.write_bytes(b"changed source")
            receipt.write_text(json.dumps({
                "status": "exact-source-commit-recovered-and-patched;offer-incomplete",
                "repository": "https://github.com/WebKit/WebKit",
                "commit": MODULE.EXPECTED_COMMIT,
                "tree": MODULE.SOURCE_TREE,
                "sourceArchiveBytes": len(b"original source"),
                "sourceArchiveSHA256": MODULE.SOURCE_ARCHIVE_SHA256,
                "patchSHA256": MODULE.EXPECTED_PATCH_SHA256,
            }))
            with patch.object(MODULE, "SOURCE_ARCHIVE", archive), \
                    patch.object(MODULE, "SOURCE_RECOVERY", receipt):
                with self.assertRaisesRegex(MODULE.PackageError, "does not match"):
                    MODULE.verify_source_archive_identity()

    def test_source_offer_binds_overlay_assets_to_named_overlay_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            overlays = root / "overlays"
            components = []
            for index in range(8):
                overlay = overlays / f"overlay-{index}"
                overlay.mkdir(parents=True)
                assets = []
                for asset_index in range(8):
                    asset_path = f"Source/WebCore/Resources/asset-{index}-{asset_index}.bin"
                    asset = overlay / asset_path
                    asset.parent.mkdir(parents=True, exist_ok=True)
                    asset.write_bytes(f"asset-{index}-{asset_index}".encode())
                    assets.append({"path": asset_path, "sha256": MODULE.sha256(asset)})
                attribution = {"assets": assets}
                attribution_path = overlay / "ATTRIBUTION.json"
                attribution_path.write_text(json.dumps(attribution), encoding="utf-8")
                components.append({
                    "path": f"overlays/overlay-{index}/ATTRIBUTION.json",
                    "bytes": attribution_path.stat().st_size,
                    "sha256": MODULE.sha256(attribution_path),
                })
                for row in assets:
                    asset = overlay / row["path"]
                    components.append({"path": f"overlays/overlay-{index}/{row['path']}",
                                       "bytes": asset.stat().st_size,
                                       "sha256": row["sha256"]})
            components.extend({"path": f"filler-{index}", "bytes": 0,
                               "sha256": hashlib.sha256(b"").hexdigest(),
                               "includedInOfferFolder": True}
                              for index in range(498 - len(components)))
            for row in components:
                row["includedInOfferFolder"] = True
                if row["path"].startswith("filler-"):
                    (root / row["path"]).touch()
            manifest_path = root / "manifest.json"
            source = {"sourceArchive": "filler-0", "sourceArchiveBytes": 0,
                      "sourceArchiveSHA256": hashlib.sha256(b"").hexdigest()}
            manifest_path.write_text(json.dumps({"sourceOfferComponentCount": len(components),
                                                 "sourceOfferComponents": components, "source": source}),
                                     encoding="utf-8")
            replacements = MODULE.source_offer_replacements(root, MODULE.sha256(manifest_path))
            self.assertEqual(len(replacements), 64)
            self.assertEqual(replacements["Source/WebCore/Resources/asset-3-2.bin"],
                             MODULE.sha256(overlays / "overlay-3/Source/WebCore/Resources/asset-3-2.bin"))
            source["sourceArchive"] = "missing-manager-archive"
            manifest_path.write_text(json.dumps({"sourceOfferComponentCount": len(components),
                                                 "sourceOfferComponents": components, "source": source}),
                                     encoding="utf-8")
            with self.assertRaisesRegex(MODULE.PackageError, "source-offer overlay inventory is invalid"):
                MODULE.source_offer_replacements(root, MODULE.sha256(manifest_path))

    def test_filtered_offer_selects_only_its_hash_bound_crosswalk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_rel = "upstream/WebKit-filtered.tar.zst"
            crosswalk_rel = "docs/evidence/crosswalk-v382.json"
            provenance_rel = "evidence/provenance-v382.json"
            scope_patch_rel = "patches/scope-v382.patch"
            text_patch_rel = "patches/webkit-text-extraction-filter-macos-deployment-gate-v377.patch"
            prediction_patch_rel = "patches/webkit-coreprediction-model-macos-deployment-gate-v381.patch"
            patch_data = {scope_patch_rel: b"scope", text_patch_rel: b"text",
                          prediction_patch_rel: b"prediction"}
            patch_hashes = {path: hashlib.sha256(data).hexdigest()
                            for path, data in patch_data.items()}
            omitted = {
                "Source/WebKit/Resources/TextExtractionFilter.mlmodel":
                    "87a4e82b476fb7e61482c243230fffa319b5108319167f340db5ff8e9d48693f",
                "Source/WebKit/Resources/ResourceLoadStatistics/corePrediction_model":
                    "221555a2cdd2e957f18d478c4b9fd01f308c1613e6e10840cce924e5f543091a",
            }
            files = {
                archive_rel: b"filtered archive",
                **patch_data,
                crosswalk_rel: json.dumps({
                    "filteredSourceOffer": {
                        "archiveSHA256": hashlib.sha256(b"filtered archive").hexdigest(),
                        "excludedSourcePaths": sorted(omitted),
                    },
                    "excludedRuntimeRows": {
                        "count": 4,
                        "status": "UNKNOWN until exact full-build and staged-candidate absence proof",
                        "sourceRows": [
                            {"mappedSources": [{"path": path, "sha256": digest}]}
                            for path, digest in (
                                ("Source/WebKit/Resources/TextExtractionFilter.mlmodel", omitted["Source/WebKit/Resources/TextExtractionFilter.mlmodel"]),
                                ("Source/WebKit/Resources/TextExtractionFilter.mlmodel", omitted["Source/WebKit/Resources/TextExtractionFilter.mlmodel"]),
                                ("Source/WebKit/Resources/TextExtractionFilter.mlmodel", omitted["Source/WebKit/Resources/TextExtractionFilter.mlmodel"]),
                                ("Source/WebKit/Resources/ResourceLoadStatistics/corePrediction_model", omitted["Source/WebKit/Resources/ResourceLoadStatistics/corePrediction_model"]),
                            )
                        ],
                    },
                }).encode(),
                provenance_rel: json.dumps({
                    "status": "DERIVED_FROM_PINNED_UPSTREAM_ARCHIVE; BUILD_AND_RUNTIME_ABSENCE_UNPROVEN",
                    "derivedArchive": {"sha256": hashlib.sha256(b"filtered archive").hexdigest()},
                    "upstream": {"archiveSHA256": MODULE.SOURCE_ARCHIVE_SHA256},
                    "excludedSourceAssets": [{"path": path, "sha256": digest}
                                              for path, digest in omitted.items()],
                    "patches": [text_patch_rel, prediction_patch_rel, scope_patch_rel],
                }).encode(),
            }
            components = []
            for relative, data in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                components.append({"path": relative, "bytes": len(data),
                                   "sha256": hashlib.sha256(data).hexdigest(),
                                   "includedInOfferFolder": True})
            by_path = {row["path"]: row for row in components}
            binding = {
                "crosswalkPath": crosswalk_rel,
                "crosswalkSHA256": by_path[crosswalk_rel]["sha256"],
                "provenancePath": provenance_rel,
                "provenanceSHA256": by_path[provenance_rel]["sha256"],
                "derivedArchiveSHA256": by_path[archive_rel]["sha256"],
                "scopePatchPath": scope_patch_rel,
                "scopePatchSHA256": patch_hashes[scope_patch_rel],
            }
            offer = {
                "sourceOfferComponents": components,
                "componentBoundaries": {"webkitSourceArchive": archive_rel},
                "currentWebKitV382FilteredModelSource": binding,
            }
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(offer), encoding="utf-8")
            with patch.object(MODULE, "V377_TEXT_EXTRACTION_PATCH_SHA256",
                              patch_hashes[text_patch_rel]), \
                    patch.object(MODULE, "V381_CORE_PREDICTION_PATCH_SHA256",
                                 patch_hashes[prediction_patch_rel]), \
                    patch.object(MODULE, "V382_FILTERED_MODEL_SCOPE_PATCH_SHA256",
                                 patch_hashes[scope_patch_rel]):
                path, digest, selected = MODULE.source_crosswalk_binding(
                    root, MODULE.sha256(manifest))
            self.assertEqual(path, root / crosswalk_rel)
            self.assertEqual(digest, binding["crosswalkSHA256"])
            self.assertEqual(selected["derivedArchiveSHA256"], binding["derivedArchiveSHA256"])

            binding["crosswalkSHA256"] = "0" * 64
            manifest.write_text(json.dumps(offer), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.PackageError, "crosswalk binding is invalid"):
                MODULE.source_crosswalk_binding(root, MODULE.sha256(manifest))

    def test_filtered_build_receipt_requires_exact_offer_hash_and_all_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "filtered-build.json"
            outputs = [{"path": target, "bytes": 1,
                        "sha256": hashlib.sha256(target.encode()).hexdigest(),
                        "architecture": "arm64"}
                       for target in sorted(MODULE.BUILD_TARGETS)]
            receipt = {
                "schemaVersion": 1,
                "id": "neantik-v382-filtered-model-webkit-build",
                "status": "PASS_FILTERED_MODEL_WEBKIT_BUILD_14_OF_14_ARM64; NOT_SIGNED",
                "inputs": {
                    "webkitCommit": MODULE.EXPECTED_COMMIT,
                    "sourceArchiveSHA256": "a" * 64,
                    "mainSourcePatchSHA256": MODULE.EXPECTED_PATCH_SHA256,
                    "v36PatchSHA256": MODULE.V36_PATCH_SHA256,
                    "patchSHA256s": {
                        "webkit-v20-source-modifications.patch": MODULE.EXPECTED_PATCH_SHA256,
                        "patches/webkit-empty-webkit-infoplist-strings-exclusion-v36.patch": MODULE.V36_PATCH_SHA256,
                        "patches/webkit-text-extraction-filter-macos-deployment-gate-v377.patch": MODULE.V377_TEXT_EXTRACTION_PATCH_SHA256,
                        "patches/webkit-coreprediction-model-macos-deployment-gate-v381.patch": MODULE.V381_CORE_PREDICTION_PATCH_SHA256,
                        "patches/webkit-filtered-model-assets-deployment-scope-v382.patch": MODULE.V382_FILTERED_MODEL_SCOPE_PATCH_SHA256,
                    },
                },
                "environment": {"hostArchitecture": "arm64", "deploymentTarget": "15.4"},
                "build": {"requestedActions": 1},
                "checks": {"outputCount": 14, "allPresent": True,
                            "allArm64": True, "ninjaDryRunNoWork": True},
                "outputs": outputs,
            }
            path.write_text(json.dumps(receipt), encoding="utf-8")
            binding = {"derivedArchiveSHA256": "a" * 64,
                       "buildReceiptSHA256": MODULE.sha256(path)}
            loaded = MODULE.load_build_receipt(path, binding)
            self.assertEqual(len(loaded["outputs"]), 14)

            receipt["outputs"].pop()
            path.write_text(json.dumps(receipt), encoding="utf-8")
            binding["buildReceiptSHA256"] = MODULE.sha256(path)
            with self.assertRaisesRegex(MODULE.PackageError, "pinned build"):
                MODULE.load_build_receipt(path, binding)

    def test_filtered_offer_cannot_reuse_historical_unfiltered_build_receipt(self):
        historical = MODULE.ROOT / "docs/evidence/neantik-v135-clean-relocated-v132-webkit-relink-20261026.json"
        binding = {"derivedArchiveSHA256": "f" * 64,
                   "buildReceiptSHA256": MODULE.sha256(historical)}
        with self.assertRaisesRegex(MODULE.PackageError, "pinned build"):
            MODULE.load_build_receipt(historical, binding)

    def test_filtered_build_receipt_must_be_a_component_of_exact_offer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            relative = "evidence/filtered-build.json"
            receipt = root / relative
            receipt.parent.mkdir()
            receipt.write_text("{}", encoding="utf-8")
            component = {"path": relative, "bytes": receipt.stat().st_size,
                         "sha256": MODULE.sha256(receipt),
                         "includedInOfferFolder": True}
            binding = {"buildReceiptPath": relative,
                       "buildReceiptSHA256": component["sha256"]}
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"sourceOfferComponents": [component]}),
                                encoding="utf-8")
            manifest_hash = MODULE.sha256(manifest)
            MODULE.verify_filtered_build_receipt_offer_binding(
                receipt, root, manifest_hash, binding)
            with self.assertRaisesRegex(MODULE.PackageError, "not bound inside"):
                MODULE.verify_filtered_build_receipt_offer_binding(
                    root / "not-the-offer-receipt.json", root, manifest_hash, binding)

    def test_source_offer_rejects_asset_outside_its_pinned_component_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            overlays = root / "overlays"
            components = []
            for index in range(8):
                overlay = overlays / f"overlay-{index}"
                overlay.mkdir(parents=True)
                assets = []
                for asset_index in range(8):
                    asset_path = f"Source/WebCore/Resources/asset-{index}-{asset_index}.bin"
                    asset = overlay / asset_path
                    asset.parent.mkdir(parents=True, exist_ok=True)
                    asset.write_bytes(f"asset-{index}-{asset_index}".encode())
                    assets.append({"path": asset_path, "sha256": MODULE.sha256(asset)})
                attribution = {"assets": assets}
                attribution_path = overlay / "ATTRIBUTION.json"
                attribution_path.write_text(json.dumps(attribution), encoding="utf-8")
                components.append({"path": f"overlays/overlay-{index}/ATTRIBUTION.json",
                                   "bytes": attribution_path.stat().st_size,
                                   "sha256": MODULE.sha256(attribution_path)})
                for row in assets:
                    asset = overlay / row["path"]
                    components.append({"path": f"overlays/overlay-{index}/{row['path']}",
                                       "bytes": asset.stat().st_size, "sha256": "0" * 64})
            components.extend({"path": f"filler-{index}", "bytes": 0,
                               "sha256": hashlib.sha256(b"").hexdigest(),
                               "includedInOfferFolder": True}
                              for index in range(498 - len(components)))
            for row in components:
                row["includedInOfferFolder"] = True
                if row["path"].startswith("filler-"):
                    (root / row["path"]).touch()
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps({"sourceOfferComponentCount": len(components),
                                                 "sourceOfferComponents": components}),
                                     encoding="utf-8")
            with self.assertRaisesRegex(MODULE.PackageError, "inventory is invalid"):
                MODULE.source_offer_replacements(root, MODULE.sha256(manifest_path))


if __name__ == "__main__":
    unittest.main()
