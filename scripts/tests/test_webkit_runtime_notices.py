import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "webkit_runtime_notices.py"
SPEC = importlib.util.spec_from_file_location("webkit_runtime_notices", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ROOT = SCRIPT.parents[1]
SOURCE_OFFERS_ROOT = Path(os.environ.get("NEANTIK_TEST_SOURCE_OFFERS_ROOT", str(ROOT / "dist/private/source-offers")))
# The runtime fixture is explicitly supplied by the operator. Its contents are
# still checked by each notice verifier against the pinned hashes.
RUNTIME_FIXTURE = Path(os.environ.get(
    "NEANTIK_TEST_RUNTIME_FRAMEWORKS",
    str(ROOT / "dist/private/candidates/ef2ce9cf159242c3a147027867403460/NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/Frameworks"),
))


class WebKitRuntimeNoticeTests(unittest.TestCase):
    def test_webcore_input_hashes_are_not_mislabeled_as_runtime_image_hashes(self):
        review_sha256 = "a" * 64
        markdown = "\n".join((
            MODULE.render_webcore_popover_markdown(review_sha256),
            MODULE.render_webcore_colordata_markdown(review_sha256),
            MODULE.render_webcore_css_generated_markdown(review_sha256),
        ))
        html = "\n".join((
            MODULE.render_webcore_popover_html(review_sha256),
            MODULE.render_webcore_colordata_html(review_sha256),
            MODULE.render_webcore_css_generated_html(review_sha256),
        ))

        self.assertEqual(markdown.count("Build-stage source-input SHA-256"), 2)
        self.assertEqual(markdown.count("WebCore build-stage source-input SHA-256"), 1)
        self.assertEqual(html.count("Build-stage source-input SHA-256"), 2)
        self.assertEqual(html.count("WebCore build-stage source-input SHA-256"), 1)
        self.assertNotIn("Runtime image SHA-256", markdown)
        self.assertNotIn("Runtime image SHA-256", html)

    def test_libaom_source_header_notices_are_pinned_and_rendered(self):
        manifest, notices = MODULE._webrtc_notice_sources(ROOT)
        self.assertEqual(manifest["noticeFileCount"], 63)
        libaom = [row for row in notices if row[1].as_posix().startswith(
            "files/supplements/libaom-header-notices/")]
        self.assertEqual(len(libaom), 3)
        self.assertEqual(
            {row[2] for row in libaom},
            {
                "e3e3ab2b97f7a96a21419325dad84480f21fc6bd5ba24273ec3aaa343631c835",
                "03b3db473e450324247971eddbf5a48f437edcfe105be307966ad3bd72411f0e",
            },
        )
        markdown = MODULE.render_webrtc_markdown("a" * 64, manifest, notices)
        html = MODULE.render_webrtc_html("a" * 64, manifest, notices)
        self.assertIn("Source notice files: 62", markdown)
        self.assertIn("Pre-signing build-stage image SHA-256: `" + "a" * 64, markdown)
        self.assertNotIn("Runtime image SHA-256", markdown)
        self.assertIn("Pre-signing build-stage image SHA-256: <code>" + "a" * 64, html)
        self.assertNotIn("Runtime image SHA-256", html)
        self.assertIn("WebKit source archive recorded by the notice manifest SHA-256", markdown)
        self.assertIn("aom_external_partition.h.notice", markdown)
        self.assertIn("aom_tpl.h.notice", html)
        self.assertIn("Alliance for Open Media Patent License notices", html)

    def test_ircam_listen_hrtf_permission_is_bound_to_exact_resource_and_notice(self):
        notice_path = self.root / MODULE.IRCAM_LISTEN_HRTF_NOTICE_SOURCE
        notice_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.IRCAM_LISTEN_HRTF_NOTICE_SOURCE, notice_path)
        runtime_frameworks = self.root / "Frameworks"
        runtime_path = runtime_frameworks / MODULE.IRCAM_LISTEN_HRTF_RUNTIME_PATH
        runtime_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            RUNTIME_FIXTURE / "WebCore.framework/Versions/A/Resources/audio/Composite.wav",
            runtime_path,
        )

        binding = MODULE._ircam_listen_hrtf_notice(self.root, runtime_frameworks)
        self.assertEqual(binding["runtimeSHA256"], MODULE.IRCAM_LISTEN_HRTF_RUNTIME_SHA256)
        self.assertEqual(binding["noticeSHA256"], MODULE.IRCAM_LISTEN_HRTF_NOTICE_SHA256)

        runtime_path.write_bytes(runtime_path.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "differs from cleared source bytes"):
            MODULE._ircam_listen_hrtf_notice(self.root, runtime_frameworks)

        runtime_path.write_bytes(
            (RUNTIME_FIXTURE / "WebCore.framework/Versions/A/Resources/audio/Composite.wav").read_bytes())
        notice_path.write_bytes(notice_path.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "differs from pinned terms summary"):
            MODULE._ircam_listen_hrtf_notice(self.root, runtime_frameworks)

    def test_v382_filtered_build_receipt_is_exact_runtime_hash_authority(self):
        source_offer = SOURCE_OFFERS_ROOT / "v382-filtered-model-assets-draft"
        hashes = MODULE._v382_runtime_hashes(ROOT, source_offer)
        self.assertIsNotNone(hashes)
        self.assertEqual(len(hashes), 16)  # 14 images, nested WebKitSwift, and compiled Assets.car.
        relative = Path("WebGPU.framework/Versions/A/WebGPU")
        receipt_hash = "453b3bd98f7ea0c3d5dc31fc7e5e2c045578a2f6eb0f81315d37efc3e9143361"
        self.assertEqual(hashes[relative.as_posix()], receipt_hash)
        self.assertEqual(hashes["WebKit.framework/Versions/A/Resources/Assets.car"],
                         "7f12d3e66db0813cdbfbef7125bab3844f5d8d6900d7ed36ea2c49e523e6ae61")
        token = MODULE._CURRENT_V382_RUNTIME_HASHES.set(hashes)
        try:
            self.assertEqual(MODULE._current_runtime_hash(relative, MODULE.WEBGPU_IMAGE_SHA256),
                             receipt_hash)
        finally:
            MODULE._CURRENT_V382_RUNTIME_HASHES.reset(token)
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            image = frameworks / relative
            image.parent.mkdir(parents=True)
            image.write_bytes(b"pre-sign runtime image")
            local_hash = MODULE.sha256_file(image)
            token = MODULE._CURRENT_V382_RUNTIME_HASHES.set({relative.as_posix(): local_hash})
            try:
                self.assertEqual(MODULE._runtime_image_build_sha(
                    frameworks, relative, MODULE.WEBGPU_IMAGE_SHA256), local_hash)
            finally:
                MODULE._CURRENT_V382_RUNTIME_HASHES.reset(token)
            image.write_bytes(b"tampered runtime image")
            token = MODULE._CURRENT_V382_RUNTIME_HASHES.set({relative.as_posix(): local_hash})
            try:
                with self.assertRaisesRegex(MODULE.NoticeError, "runtime image SHA-256 mismatch"):
                    MODULE._runtime_image_build_sha(frameworks, relative,
                                                    MODULE.WEBGPU_IMAGE_SHA256)
            finally:
                MODULE._CURRENT_V382_RUNTIME_HASHES.reset(token)

    def test_current_v409_v382_v399_offer_is_an_exact_runtime_hash_authority(self):
        source_offer = SOURCE_OFFERS_ROOT / "v409-v382-v399-current-recipient-map-draft"
        hashes = MODULE._v382_runtime_hashes(ROOT, source_offer)
        self.assertIsNotNone(hashes)
        self.assertEqual(hashes["libwebrtc.dylib"],
                         "309d95abf602e59d25bf3dc38abe719edc10829ff79cb6a917027edad43e965f")

    def test_cli_verify_uses_source_offer_environment(self):
        app = self.root / "NeAntik.app"
        source_offer = self.root / "source-offer"
        with mock.patch.object(
                MODULE.sys, "argv",
                [str(SCRIPT), "--verify", "--app", str(app)]), \
             mock.patch.dict(
                 MODULE.os.environ,
                 {"NEANTIK_WEBKIT_SOURCE_OFFER_ROOT": str(source_offer)}), \
             mock.patch.object(
                 MODULE, "verify_owned_webkit_notices",
                 return_value={"licenseSHA256": "test", "webcoreLGPL2SHA256": "test",
                               "webcoreLGPL21SHA256": "test"}) as verify:
            self.assertEqual(MODULE.main(), 0)
        verify.assert_called_once_with(
            app, None, project_root=MODULE.PROJECT_ROOT,
            source_offer_root=source_offer, source_offer_manifest_sha256=None)

    def test_cli_source_offer_argument_overrides_environment(self):
        app = self.root / "NeAntik.app"
        source_offer = self.root / "source-offer-argument"
        with mock.patch.object(
                MODULE.sys, "argv",
                [str(SCRIPT), "--verify", "--app", str(app),
                 "--source-offer-root", str(source_offer)]), \
             mock.patch.dict(
                 MODULE.os.environ,
                 {"NEANTIK_WEBKIT_SOURCE_OFFER_ROOT": str(self.root / "ignored")}), \
             mock.patch.object(
                 MODULE, "verify_owned_webkit_notices",
                 return_value={"licenseSHA256": "test", "webcoreLGPL2SHA256": "test",
                               "webcoreLGPL21SHA256": "test"}) as verify:
            self.assertEqual(MODULE.main(), 0)
        verify.assert_called_once_with(
            app, None, project_root=MODULE.PROJECT_ROOT,
            source_offer_root=source_offer, source_offer_manifest_sha256=None)

    def test_v135_runtime_bindings_match_exact_build_receipt_and_fail_closed(self):
        real_check = self.real_v135_binding_check
        with mock.patch.multiple(
                MODULE,
                JSC_HEADERLESS_BSD2_IMAGE_SHA256="8e6d73e593ee32196767b35a236cffc1f172bd12f23073cdc35ef290f506ef63",
                JSC_HEADERLESS_BSD2_REVIEW_SHA256="e5096eec97de1fe998990e19d546e5ed15ea4056f007f8660699d7b5bd5f74c9",
                JSC_GENERATED_OUTPUT_MANIFEST_SHA256="845bd7528fa35415a53be226137daf30b2d31fce6f3d6264486f5f2a809799e4",
                WEBGPU_IMAGE_SHA256="42e1a8d4205948576032c04a428788cd737d06512aac044cc04acb1608b0dc23",
                WEBCORE_POPOVER_RUNTIME_SHA256="2dfb23280d68b0b89bf493a16de3696a326ccf8cdb88722593998bb00bbdd6a8",
                WEBCORE_POPOVER_REVIEW_SHA256="d865038a8903b114ef6fb3858e1c750b1f2c17b75f161cad32902481b4cc7f81",
                WEBCORE_COLORDATA_REVIEW_SHA256="0db71a6e54737e9d88e194737fedd4ff1e6540a464c6d7f35b879d616985386e",
                WEBCORE_CSS_GENERATED_REVIEW_SHA256="896b02761d0b256d705ff26cf58c39b9d3157e52fb3699435e22be6522e683bc",
                WEBKIT_SWIFT_MANIFEST_SHA256="86beb8321aa67d5af9ac5d499d1ba0aa0528c15a29900ece3f17791c6b8f38ec",
                WEBKIT_XPC_ENTRYPOINT_MAP_SHA256="74b11548a75a17840fbfff59109c479de60b7da9bbe0d8f54a14fefffa7eb3b3"):
            summary = real_check(ROOT)
            self.assertEqual(len(summary["outputs"]), 14)

            with tempfile.TemporaryDirectory() as temporary:
                copied_root = Path(temporary)
                evidence = copied_root / "docs/evidence/v135-runtime-notice-bindings"
                shutil.copytree(ROOT / "docs/evidence/v135-runtime-notice-bindings", evidence)
                receipt = copied_root / MODULE.V135_BUILD_RECEIPT
                receipt.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / MODULE.V135_BUILD_RECEIPT, receipt)
                summary_path = copied_root / MODULE.V135_RUNTIME_BINDING_SUMMARY
                summary_path.write_bytes(summary_path.read_bytes() + b" ")
                with self.assertRaisesRegex(MODULE.NoticeError,
                                            "V135 runtime binding summary or build receipt"):
                    real_check(copied_root)

    def test_first_party_media_controls_overlay_binds_all_runtime_assets(self):
        source_offer = self.root / "offer"
        source_offer.mkdir()
        overlay_source = SOURCE_OFFERS_ROOT / "v282-composite-source-offer-draft" / MODULE.WEBCORE_MEDIA_CONTROLS_OVERLAY_RELATIVE
        shutil.copytree(overlay_source, source_offer / MODULE.WEBCORE_MEDIA_CONTROLS_OVERLAY_RELATIVE)
        frameworks = self.root / "Frameworks"
        runtime_images = (frameworks / "WebCore.framework/Versions/A/Resources/modern-media-controls/images")
        attribution = json.loads((overlay_source / "ATTRIBUTION.json").read_text())
        for row in attribution["assets"]:
            relative = Path(row["path"]).relative_to("Source/WebCore/Modules/modern-media-controls/images/macOS")
            destination = runtime_images / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(overlay_source / "Source" / Path(row["path"]).relative_to("Source"), destination)

        binding = MODULE._webcore_media_controls_overlay(ROOT, frameworks, source_offer)
        self.assertEqual(len(binding["runtimeAssets"]), 35)
        self.assertEqual(binding["licenseSHA256"], MODULE.sha256_file(overlay_source / "LICENSE.txt"))

        changed = runtime_images / Path(attribution["assets"][0]["path"]).name
        changed.write_bytes(changed.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "does not match first-party overlay"):
            MODULE._webcore_media_controls_overlay(ROOT, frameworks, source_offer)

    def test_first_party_webcore_replacement_groups_bind_notices_and_runtime(self):
        original_offer = SOURCE_OFFERS_ROOT / "v359-webmodel-resource-closure"
        original_frameworks = RUNTIME_FIXTURE
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            offer = root / "offer"
            frameworks = root / "Frameworks"
            manifest = json.loads((original_offer / "manifest.json").read_text())
            names = (
                "neantik-core-ui-original-v1", "neantik-original-cursors-v1",
                "neantik-delete-button-first-party-v1", "neantik-linear-srgb-icc-v1",
                "neantik-first-party-webcore-contentfilter-v1",
            )
            expected_component_paths = set()
            total_assets = 0
            for name in names:
                source = original_offer / "overlays" / name
                destination = offer / "overlays" / name
                shutil.copytree(source, destination)
                attribution = json.loads((source / "ATTRIBUTION.json").read_text())
                total_assets += len(attribution["assets"])
                expected_component_paths.update((f"overlays/{name}/ATTRIBUTION.json",
                                                 f"overlays/{name}/LICENSE.txt"))
                for row in attribution["assets"]:
                    relative = Path("WebCore.framework/Versions/A/Resources") / Path(row["path"]).name
                    runtime = frameworks / relative
                    runtime.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(original_frameworks / relative, runtime)
                    expected_component_paths.add(f"overlays/{name}/{row['path']}")
            offer.mkdir(exist_ok=True)
            manifest["sourceOfferComponents"] = [
                row for row in manifest["sourceOfferComponents"]
                if row["path"] in expected_component_paths
            ]
            (offer / "manifest.json").write_text(json.dumps(manifest))

            bindings = MODULE._webcore_first_party_resource_overlays(frameworks, offer)
            self.assertEqual(sum(len(row["runtimeAssets"]) for row in bindings), total_assets)
            self.assertEqual(len(bindings), 5)
            markdown = MODULE.render_webcore_first_party_markdown(bindings)
            html = MODULE.render_webcore_first_party_html(bindings)
            self.assertIn("BSD-2-Clause", markdown)
            self.assertIn(MODULE.WEBCORE_FIRST_PARTY_HTML_MARKER, html)

            first = next(iter(bindings[0]["runtimeAssets"]))
            runtime = frameworks / first
            runtime.write_bytes(runtime.read_bytes() + b"tampered")
            with self.assertRaisesRegex(MODULE.NoticeError, "runtime resource differs"):
                MODULE._webcore_first_party_resource_overlays(frameworks, offer)

    def test_first_party_engine_notices_are_written_verified_and_idempotent(self):
        original_offer = SOURCE_OFFERS_ROOT / "v359-webmodel-resource-closure"
        offer = self.root / "source-offer"
        names = (
            "neantik-core-ui-original-v1", "neantik-original-cursors-v1",
            "neantik-delete-button-first-party-v1", "neantik-linear-srgb-icc-v1",
            "neantik-first-party-webcore-contentfilter-v1",
        )
        source_manifest = json.loads((original_offer / "manifest.json").read_text())
        component_paths = set()
        for name in names:
            shutil.copytree(original_offer / "overlays" / name, offer / "overlays" / name)
            component_paths.update((f"overlays/{name}/ATTRIBUTION.json", f"overlays/{name}/LICENSE.txt"))
            attribution = json.loads((original_offer / "overlays" / name / "ATTRIBUTION.json").read_text())
            for row in attribution["assets"]:
                component_paths.add(f"overlays/{name}/{row['path']}")
                relative = Path("WebCore.framework/Versions/A/Resources") / Path(row["path"]).name
                runtime = self.frameworks / relative
                runtime.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(
                    original_offer / "overlays" / name / row["path"], runtime)

        warning_name = "neantik-first-party-warning-colors-v1"
        warning_source = original_offer / "overlays" / warning_name
        shutil.copytree(warning_source, offer / "overlays" / warning_name)
        warning_attribution = json.loads((warning_source / "ATTRIBUTION.json").read_text())
        component_paths.update((f"overlays/{warning_name}/ATTRIBUTION.json",
                                f"overlays/{warning_name}/LICENSE.txt"))
        component_paths.update(f"overlays/{warning_name}/{row['path']}"
                               for row in warning_attribution["assets"])
        candidate_car = (RUNTIME_FIXTURE / "WebKit.framework/Versions/A/Resources/Assets.car")
        runtime_car = (self.frameworks / "WebKit.framework/Versions/A/Resources/Assets.car")
        runtime_car.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(candidate_car, runtime_car)

        media_relative = MODULE.WEBCORE_MEDIA_CONTROLS_OVERLAY_RELATIVE
        shutil.copytree(original_offer / media_relative, offer / media_relative)
        media_attribution = json.loads((offer / media_relative / "ATTRIBUTION.json").read_text())
        for row in media_attribution["assets"]:
            relative = (Path("WebCore.framework/Versions/A/Resources/modern-media-controls/images")
                        / Path(row["path"]).relative_to(
                            "Source/WebCore/Modules/modern-media-controls/images/macOS"))
            runtime = self.frameworks / relative
            runtime.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(offer / media_relative / "Source" / Path(row["path"]).relative_to("Source"), runtime)

        source_manifest["sourceOfferComponents"] = [
            row for row in source_manifest["sourceOfferComponents"] if row["path"] in component_paths
        ]
        (offer / "manifest.json").write_text(json.dumps(source_manifest))
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root, source_offer_root=offer)
        result = MODULE.verify_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root, source_offer_root=offer)
        self.assertTrue(result)
        first_markdown = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        first_html = (self.app / MODULE.HTML_DESTINATION).read_bytes()
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root, source_offer_root=offer)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), first_markdown)
        self.assertEqual((self.app / MODULE.HTML_DESTINATION).read_bytes(), first_html)
        for name in names:
            root = (self.app / MODULE.WEBCORE_FIRST_PARTY_NOTICE_ROOT / name)
            self.assertTrue((root / "LICENSE.txt").is_file())
            self.assertTrue((root / "ATTRIBUTION.json").is_file())
        warning_root = self.app / MODULE.WEBKIT_WARNING_COLOR_NOTICE_ROOT / warning_name
        self.assertTrue((warning_root / "LICENSE.txt").is_file())
        self.assertTrue((warning_root / "ATTRIBUTION.json").is_file())
        notices = (self.app / MODULE.NOTICE_DESTINATION).read_text()
        self.assertEqual(notices.count(MODULE.WEBCORE_FIRST_PARTY_SECTION_MARKER), 1)
        self.assertEqual(notices.count(MODULE.WEBKIT_WARNING_COLOR_SECTION_MARKER), 1)

    def setUp(self):
        self.real_v135_binding_check = MODULE._validate_v135_runtime_binding_evidence
        self.v135_binding_check = mock.patch.object(
            MODULE, "_validate_v135_runtime_binding_evidence", return_value={})
        self.v135_binding_check.start()
        self.addCleanup(self.v135_binding_check.stop)
        self.real_runtime_image_check = MODULE._verify_webkit_swift_runtime_images
        self.runtime_image_check = mock.patch.object(
            MODULE, "_verify_webkit_swift_runtime_images")
        self.runtime_image_check.start()
        self.addCleanup(self.runtime_image_check.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "runtime/licenses").mkdir(parents=True)
        ircam_notice = self.root / MODULE.IRCAM_LISTEN_HRTF_NOTICE_SOURCE
        ircam_notice.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.IRCAM_LISTEN_HRTF_NOTICE_SOURCE, ircam_notice)
        shutil.copyfile(
            ROOT / MODULE.LICENSE_SOURCE,
            self.root / MODULE.LICENSE_SOURCE,
        )
        framework_license = self.root / MODULE.WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE
        framework_license.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE,
                        framework_license)
        lgpl2_source = self.root / MODULE.WEBCORE_LGPL2_SOURCE
        lgpl2_source.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / MODULE.WEBCORE_LGPL2_SOURCE, lgpl2_source)
        shutil.copyfile(ROOT / MODULE.WEBCORE_LGPL21_SOURCE,
                        self.root / MODULE.WEBCORE_LGPL21_SOURCE)
        for source, _digest, _destination in (
                (MODULE.JSC_UNICODE_LICENSE_SOURCE, MODULE.JSC_UNICODE_LICENSE_SHA256,
                 MODULE.JSC_UNICODE_LICENSE_DESTINATION),
                (MODULE.JSC_MPL11_SOURCE, MODULE.JSC_MPL11_SHA256,
                 MODULE.JSC_MPL11_DESTINATION),
                (MODULE.JSC_GPL2_SOURCE, MODULE.JSC_GPL2_SHA256,
                 MODULE.JSC_GPL2_DESTINATION)):
            destination = self.root / source
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, destination)
        lineage = self.root / MODULE.JSC_GENERATED_LINEAGE_SOURCE
        lineage.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.JSC_GENERATED_LINEAGE_SOURCE, lineage)
        for source in (MODULE.ANGLE_LICENSE_SOURCE, MODULE.XXHASH_LICENSE_SOURCE,
                       MODULE.CHROMIUM_ANGLE_LICENSE_SOURCE):
            destination = self.root / source
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, destination)
        for name, _digest, _size in MODULE.WEBINSPECTOR_LICENSES:
            source = Path("docs/evidence/third-party/webinspector") / name / "LICENSE"
            destination = self.root / source
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, destination)
        shutil.copytree(
            ROOT / MODULE.WEBRTC_CANDIDATE_ROOT,
            self.root / MODULE.WEBRTC_CANDIDATE_ROOT,
        )
        shutil.copytree(
            ROOT / MODULE.LINKED_HEADERS_SOURCE_ROOT,
            self.root / MODULE.LINKED_HEADERS_SOURCE_ROOT,
        )
        generated_headers = self.root / MODULE.WEBCORE_GENERATED_HEADERS_SOURCE
        generated_headers.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.WEBCORE_GENERATED_HEADERS_SOURCE,
                        generated_headers)
        webrtc_generated_headers = self.root / MODULE.WEBRTC_GENERATED_HEADERS_SOURCE
        webrtc_generated_headers.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.WEBRTC_GENERATED_HEADERS_SOURCE,
                        webrtc_generated_headers)
        mpl2_source = self.root / MODULE.WEBRTC_MPL2_SOURCE
        mpl2_source.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.WEBRTC_MPL2_SOURCE, mpl2_source)
        shutil.copytree(
            ROOT / MODULE.SANDBOX_SOURCE_ROOT,
            self.root / MODULE.SANDBOX_SOURCE_ROOT,
        )
        crosswalk = self.root / MODULE.SOURCE_CROSSWALK
        crosswalk.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.SOURCE_CROSSWALK, crosswalk)
        shutil.copytree(ROOT / MODULE.SOURCE_CORPUS_ROOT,
                        self.root / MODULE.SOURCE_CORPUS_ROOT)
        shutil.copyfile(ROOT / MODULE.WEBGPU_LICENSE_SOURCE,
                        self.root / MODULE.WEBGPU_LICENSE_SOURCE)
        for source in (MODULE.WEBRTC_LIBWEBM_AUTHORS_SOURCE,
                       MODULE.DAV1D_HEADERS_SOURCE,
                       MODULE.RNNOISE_HEADER_SOURCE,
                       MODULE.LIBSRTP_HEADERS_SOURCE,
                       MODULE.OPUS_HEADERS_SOURCE,
                       MODULE.WEBGPU_ADAPTER_HEADER_SOURCE,
                       MODULE.JSC_COPYING_LIB_SOURCE,
                       MODULE.JSC_BINJA_ATTRIBUTION_SOURCE,
                       MODULE.JSC_BINJA_APACHE_SOURCE,
                       MODULE.WEBCORE_MODEL_IBL_LICENSE_SOURCE,
                       MODULE.WEBCORE_MODEL_IBL_ATTRIBUTION_SOURCE):
            destination = self.root / source
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, destination)
        (self.root / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE,
                        self.root / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE)
        for source in (MODULE.WEBCORE_POPOVER_LICENSE_SOURCE,
                       MODULE.WEBCORE_POPOVER_REVIEW_SOURCE,
                       MODULE.WEBCORE_COLORDATA_LICENSE_SOURCE,
                       MODULE.WEBCORE_COLORDATA_REVIEW_SOURCE,
                       MODULE.WEBCORE_CSS_GENERATED_APPLE_LICENSE_SOURCE,
                       MODULE.WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SOURCE,
                       MODULE.WEBCORE_CSS_GENERATED_REVIEW_SOURCE,
                       MODULE.WEBCORE_MEDIA_CONTROLS_REVIEW_SOURCE):
            destination = self.root / source
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, destination)
        shutil.copytree(ROOT / MODULE.WEBKIT_SWIFT_SOURCE_NOTICE_ROOT,
                        self.root / MODULE.WEBKIT_SWIFT_SOURCE_NOTICE_ROOT)
        swift_manifest = self.root / MODULE.WEBKIT_SWIFT_MANIFEST_SOURCE
        swift_manifest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.WEBKIT_SWIFT_MANIFEST_SOURCE, swift_manifest)
        xpc_notice = self.root / MODULE.WEBKIT_XPC_ENTRYPOINT_NOTICE_SOURCE
        xpc_notice.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.WEBKIT_XPC_ENTRYPOINT_NOTICE_SOURCE, xpc_notice)
        xpc_map = self.root / MODULE.WEBKIT_XPC_ENTRYPOINT_MAP
        xpc_map.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.WEBKIT_XPC_ENTRYPOINT_MAP, xpc_map)
        lineage = ROOT / "docs/evidence/webkit-v20-link-target-input-lineage-addendum-20261025.json"
        lineage_copy = self.root / "docs/evidence/webkit-v20-link-target-input-lineage-addendum-20261025.json"
        lineage_copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(lineage, lineage_copy)
        self.app = self.root / "NeAntik.app"
        resources = self.app / "Contents/Resources"
        (resources / "NeAntikRuntimeCompliance").mkdir(parents=True)
        (resources / "NeAntikRuntimeNotices.md").write_text(
            "# NeAntik Chromium runtime notices\n\nChromium component list.\n",
            encoding="utf-8",
        )
        (resources / "NeAntikRuntimeCompliance/THIRD-PARTY-NOTICES.html").write_text(
            "<!doctype html><html><body><h1>Chromium notices</h1></body></html>\n",
            encoding="utf-8",
        )
        self.frameworks = self.root / "Frameworks"
        self.frameworks.mkdir()
        overlay = ROOT / MODULE.WEBCORE_MODEL_IBL_ROOT / "runtime-resources"
        webcore_resources = (self.frameworks / "WebCore.framework/Versions/A/Resources")
        webcore_resources.mkdir(parents=True)
        hrtf_runtime = webcore_resources / "audio/Composite.wav"
        hrtf_runtime.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            RUNTIME_FIXTURE / "WebCore.framework/Versions/A/Resources/audio/Composite.wav",
            hrtf_runtime,
        )
        for name in ("modelDefaultDiffuseData", "modelDefaultSpecularData"):
            shutil.copyfile(overlay / name, webcore_resources / name)
        self.library = self.frameworks / "libswiftCompatibilitySpan.dylib"
        self.library.write_bytes(bytes.fromhex("cffaedfe") + b"test Mach-O")
        self.angle_library = self.frameworks / "libANGLE-shared.dylib"
        self.angle_library.write_bytes(bytes.fromhex("cffaedfe") + b"test ANGLE Mach-O")
        self.webrtc_library = self.frameworks / "libwebrtc.dylib"
        self.webrtc_library.write_bytes(bytes.fromhex("cffaedfe") + b"test WebRTC Mach-O")
        self.webgpu_image = self.frameworks / MODULE.WEBGPU_IMAGE_PATH
        self.webgpu_image.parent.mkdir(parents=True)
        self.webgpu_image.write_bytes(bytes.fromhex("cffaedfe") + b"test WebGPU Mach-O")
        self.webgpu_hash_patch = mock.patch.object(
            MODULE, "WEBGPU_IMAGE_SHA256", MODULE.sha256_file(self.webgpu_image))
        self.webgpu_hash_patch.start()
        self.addCleanup(self.webgpu_hash_patch.stop)
        self.jsc_image = self.frameworks / "JavaScriptCore.framework/Versions/A/JavaScriptCore"
        self.jsc_image.parent.mkdir(parents=True)
        self.jsc_image.write_bytes(bytes.fromhex("cffaedfe") + b"test JavaScriptCore Mach-O")
        self.jsc_image_hash = MODULE.sha256_file(self.jsc_image)
        image_hash_patch = mock.patch.object(
            MODULE, "JSC_HEADERLESS_BSD2_IMAGE_SHA256", self.jsc_image_hash)
        image_hash_patch.start()
        self.addCleanup(image_hash_patch.stop)
        review_path = self.root / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE
        review = json.loads(review_path.read_text(encoding="utf-8"))
        review["sourceBinding"]["runtimeImageSHA256"] = self.jsc_image_hash
        review_path.write_text(json.dumps(review, indent=2) + "\n", encoding="utf-8")
        review_hash_patch = mock.patch.object(
            MODULE, "JSC_HEADERLESS_BSD2_REVIEW_SHA256", MODULE.sha256_file(review_path))
        review_hash_patch.start()
        self.addCleanup(review_hash_patch.stop)
        generated_headers = self.root / MODULE.JSC_GENERATED_OUTPUT_HEADERS_SOURCE
        generated_headers.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.JSC_GENERATED_OUTPUT_HEADERS_SOURCE,
                        generated_headers)
        generated_manifest = self.root / MODULE.JSC_GENERATED_OUTPUT_MANIFEST_SOURCE
        generated_manifest.parent.mkdir(parents=True, exist_ok=True)
        generated_data = json.loads(
            (ROOT / MODULE.JSC_GENERATED_OUTPUT_MANIFEST_SOURCE).read_text(encoding="utf-8"))
        generated_data["runtimeImage"]["sha256"] = self.jsc_image_hash
        generated_manifest.write_text(json.dumps(generated_data, indent=2, ensure_ascii=False) + "\n",
                                      encoding="utf-8")
        generated_manifest_hash_patch = mock.patch.object(
            MODULE, "JSC_GENERATED_OUTPUT_MANIFEST_SHA256",
            MODULE.sha256_file(generated_manifest))
        generated_manifest_hash_patch.start()
        self.addCleanup(generated_manifest_hash_patch.stop)
        for name, _digest, _size in MODULE.WEBINSPECTOR_LICENSES:
            source = self.root / "docs/evidence/third-party/webinspector" / name / "LICENSE"
            resource = (self.frameworks / "WebInspectorUI.framework/Versions/A/Resources/External"
                        / name / "LICENSE")
            resource.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, resource)

    def tearDown(self):
        self.temporary.cleanup()

    def test_preflight_rejects_missing_span_without_mutating_app(self):
        self.library.unlink()
        original = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, "exactly one bundled"):
            MODULE.preflight_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), original)
        self.assertFalse((self.app / MODULE.LICENSE_DESTINATION).exists())
        self.assertFalse((self.app / MODULE.WEBGPU_LICENSE_DESTINATION).exists())
        self.assertFalse((self.app / MODULE.JSC_HEADERLESS_BSD2_LICENSE_DESTINATION).exists())
        self.assertFalse((self.app / MODULE.JSC_HEADERLESS_BSD2_REVIEW_DESTINATION).exists())
        self.assertFalse((self.app / MODULE.JSC_GENERATED_OUTPUT_DESTINATION_ROOT).exists())

    def test_generated_output_notice_inputs_are_complete_and_runtime_bound(self):
        manifest_path, headers_path, manifest = MODULE._jsc_generated_output_notices(
            self.root, self.frameworks)
        self.assertEqual(len(manifest["outputs"]), 6)
        self.assertEqual(MODULE.sha256_file(headers_path), MODULE.JSC_GENERATED_OUTPUT_HEADERS_SHA256)
        self.assertEqual(manifest["headerBundle"]["sha256"], MODULE.JSC_GENERATED_OUTPUT_HEADERS_SHA256)
        self.assertEqual(manifest["runtimeImage"]["sha256"], self.jsc_image_hash)
        self.assertEqual(manifest_path, self.root / MODULE.JSC_GENERATED_OUTPUT_MANIFEST_SOURCE)

    def test_corrupt_generated_output_header_bundle_fails_before_notice_write(self):
        path = self.root / MODULE.JSC_GENERATED_OUTPUT_HEADERS_SOURCE
        path.write_bytes(path.read_bytes() + b"changed")
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, "generated-output headers SHA-256"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_corrupt_webcore_media_asset_review_fails_before_notice_write(self):
        path = self.root / MODULE.WEBCORE_MEDIA_CONTROLS_REVIEW_SOURCE
        path.write_bytes(path.read_bytes() + b"changed")
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError,
                                    "WebCore media-controls rights review SHA-256"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)
        self.assertFalse((self.app / Path("Contents/Resources/NeAntikRuntimeLicenses/WebCore/MediaControlsAssets-BSD-2-Clause.txt")).exists())

    def test_unknown_webmodel_runtime_bytes_fail_before_notice_write(self):
        resource = self.frameworks / MODULE.WEBCORE_MODEL_IBL_DIFFUSE_PATH
        resource.write_bytes(resource.read_bytes() + b"changed")
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, "resource hashes do not match"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)
        self.assertFalse((self.app / MODULE.WEBCORE_MODEL_IBL_LICENSE_DESTINATION).exists())

    def test_install_and_verify_bind_both_notices_and_license_to_runtime(self):
        MODULE.preflight_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.LICENSE_DESTINATION).exists())
        self.assertNotIn(
            MODULE.SECTION_MARKER,
            (self.app / MODULE.NOTICE_DESTINATION).read_text(encoding="utf-8"),
        )
        notices_path = self.app / MODULE.HTML_DESTINATION
        (notices_path.parent / "compliance-manifest.json").write_text(
            json.dumps({"schemaVersion": 1, "notices": {
                "file": notices_path.name,
                "sha256": MODULE.sha256_file(notices_path),
                "entryCount": 1,
            }}), encoding="utf-8")
        result = MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        webcore_generated_headers = self.app / MODULE.WEBCORE_GENERATED_HEADERS_DESTINATION
        webcore_generated_text = webcore_generated_headers.read_text(encoding="utf-8")
        self.assertEqual(MODULE.sha256_file(webcore_generated_headers),
                         MODULE.WEBCORE_GENERATED_HEADERS_SHA256)
        for generated_name in ("JSTouch.cpp", "JSTouchEvent.cpp", "JSTouchList.cpp"):
            self.assertIn(f"DerivedSources/{generated_name}", webcore_generated_text)
        self.assertEqual(
            webcore_generated_text.count("| linked generated output header ====="), 3)
        self.assertGreaterEqual(
            webcore_generated_text.count("GNU Library General Public License"), 3)
        self.assertEqual(
            (self.app / MODULE.WEBCORE_LGPL2_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBCORE_LGPL2_SOURCE).read_bytes())
        compliance_manifest = json.loads((self.app / "Contents/Resources/NeAntikRuntimeCompliance/compliance-manifest.json").read_text())
        self.assertEqual(compliance_manifest["notices"]["sha256"],
                         MODULE.sha256_file(self.app / MODULE.HTML_DESTINATION))
        self.assertEqual(result["licenseSHA256"], MODULE.LICENSE_SHA256)
        self.assertEqual(result["webcoreLGPL2SHA256"], MODULE.WEBCORE_LGPL2_SHA256)
        self.assertEqual(result["webcoreLGPL21SHA256"], MODULE.WEBCORE_LGPL21_SHA256)
        self.assertEqual(result["jscCopyingLibSHA256"], MODULE.JSC_COPYING_LIB_SHA256)
        self.assertEqual(
            (self.app / MODULE.JSC_COPYING_LIB_DESTINATION).read_bytes(),
            (self.root / MODULE.JSC_COPYING_LIB_SOURCE).read_bytes())
        self.assertEqual(result["jscBinjaAttributionSHA256"],
                         MODULE.JSC_BINJA_ATTRIBUTION_SHA256)
        self.assertEqual(result["jscBinjaApacheSHA256"], MODULE.JSC_BINJA_APACHE_SHA256)
        self.assertEqual(
            (self.app / MODULE.JSC_BINJA_ATTRIBUTION_DESTINATION).read_bytes(),
            (self.root / MODULE.JSC_BINJA_ATTRIBUTION_SOURCE).read_bytes())
        self.assertEqual(
            (self.app / MODULE.JSC_BINJA_APACHE_DESTINATION).read_bytes(),
            (self.root / MODULE.JSC_BINJA_APACHE_SOURCE).read_bytes())
        self.assertEqual(result["jscGeneratedOutputHeaderSHA256"],
                         MODULE.JSC_GENERATED_OUTPUT_HEADERS_SHA256)
        self.assertEqual(result["webCorePopoverLicenseSHA256"], MODULE.WEBCORE_POPOVER_LICENSE_SHA256)
        self.assertEqual(result["webCorePopoverReviewSHA256"],
                         MODULE.sha256_file(self.root / MODULE.WEBCORE_POPOVER_REVIEW_SOURCE))
        self.assertEqual(result["webCoreColorDataLicenseSHA256"],
                         MODULE.WEBCORE_COLORDATA_LICENSE_SHA256)
        self.assertEqual(result["webCoreColorDataReviewSHA256"],
                         MODULE.sha256_file(self.root / MODULE.WEBCORE_COLORDATA_REVIEW_SOURCE))
        self.assertEqual(result["webCoreCSSGeneratedAppleLicenseSHA256"],
                         MODULE.WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256)
        self.assertEqual(result["webCoreCSSGeneratedLGPL2LicenseSHA256"],
                         MODULE.WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256)
        self.assertEqual(result["webCoreCSSGeneratedReviewSHA256"],
                         MODULE.sha256_file(self.root / MODULE.WEBCORE_CSS_GENERATED_REVIEW_SOURCE))
        self.assertEqual(result["webCoreMediaControlsRightsReviewSHA256"],
                         MODULE.WEBCORE_MEDIA_CONTROLS_REVIEW_SHA256)
        self.assertEqual(result["webCoreMediaControlsReviewSHA256"],
                         MODULE.sha256_file(self.root / MODULE.WEBCORE_MEDIA_CONTROLS_REVIEW_SOURCE))
        self.assertEqual(result["jscMPL11SHA256"], MODULE.JSC_MPL11_SHA256)
        self.assertEqual(result["jscGPL2SHA256"], MODULE.JSC_GPL2_SHA256)
        self.assertEqual(result["jscHeaderlessBSD2LicenseSHA256"],
                         MODULE.JSC_HEADERLESS_BSD2_LICENSE_SHA256)
        self.assertEqual(result["jscHeaderlessBSD2ReviewSHA256"],
                         MODULE.sha256_file(self.root / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE))
        self.assertEqual(result["jscHeaderlessBSD2RuntimeSHA256"], self.jsc_image_hash)
        self.assertEqual(result["jscUnicodeLicenseSHA256"], MODULE.JSC_UNICODE_LICENSE_SHA256)
        self.assertEqual(result["jscGeneratedInputLineageSHA256"],
                         MODULE.JSC_GENERATED_LINEAGE_SHA256)
        self.assertEqual(result["angleRuntimeSHA256"], MODULE.sha256_file(self.angle_library))
        self.assertEqual(result["angleLicenseSHA256"], MODULE.ANGLE_LICENSE_SHA256)
        self.assertEqual(result["xxhashLicenseSHA256"], MODULE.XXHASH_LICENSE_SHA256)
        self.assertEqual(result["webrtcRuntimeSHA256"], MODULE.sha256_file(self.webrtc_library))
        self.assertEqual(result["webrtcManifestSHA256"], MODULE.WEBRTC_MANIFEST_SHA256)
        self.assertEqual(result["webrtcNoticeCount"], "62")
        self.assertEqual(result["webInspectorExternalLicenseCount"], "4")
        self.assertEqual(result["webKitSandboxSourceNoticeCount"], "6")
        self.assertEqual(result["webKitSourceCandidateNoticeCount"], "12")
        self.assertEqual(result["webKitSwiftSourceHeaderNoticeCount"], "32")
        self.assertEqual(result["webKitSwiftSourceHeaderManifestSHA256"],
                         MODULE.WEBKIT_SWIFT_MANIFEST_SHA256)
        self.assertEqual(result["webKitXPCEntrypointNoticeCount"], "5")
        self.assertEqual(result["webgpuRuntimeSHA256"], MODULE.sha256_file(self.webgpu_image))
        self.assertEqual(result["webgpuLicenseSHA256"], MODULE.WEBGPU_LICENSE_SHA256)
        self.assertEqual(result["webCoreModelIblLicenseSHA256"],
                         MODULE.WEBCORE_MODEL_IBL_LICENSE_SHA256)
        self.assertEqual(result["webCoreModelIblAttributionSHA256"],
                         MODULE.WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256)
        self.assertEqual(result["webCoreModelIblDiffuseRuntimeSHA256"],
                         MODULE.WEBCORE_MODEL_IBL_DIFFUSE_SHA256)
        self.assertEqual(result["webCoreModelIblSpecularRuntimeSHA256"],
                         MODULE.WEBCORE_MODEL_IBL_SPECULAR_SHA256)
        self.assertEqual((self.app / MODULE.WEBCORE_MODEL_IBL_LICENSE_DESTINATION).read_bytes(),
                         (self.root / MODULE.WEBCORE_MODEL_IBL_LICENSE_SOURCE).read_bytes())
        self.assertEqual((self.app / MODULE.WEBCORE_MODEL_IBL_ATTRIBUTION_DESTINATION).read_bytes(),
                         (self.root / MODULE.WEBCORE_MODEL_IBL_ATTRIBUTION_SOURCE).read_bytes())
        self.assertEqual(
            (self.app / MODULE.JSC_HEADERLESS_BSD2_LICENSE_DESTINATION).read_bytes(),
            (self.root / MODULE.JSC_HEADERLESS_BSD2_LICENSE_SOURCE).read_bytes(),
        )
        self.assertEqual(
            (self.app / MODULE.JSC_HEADERLESS_BSD2_REVIEW_DESTINATION).read_bytes(),
            (self.root / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE).read_bytes(),
        )
        self.assertEqual(
            (self.app / MODULE.WEBGPU_LICENSE_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBGPU_LICENSE_SOURCE).read_bytes(),
        )
        self.assertFalse((self.app / Path("Contents/Resources/NeAntikRuntimeLicenses/WebCore/MediaControlsAssets-BSD-2-Clause.txt")).exists())
        self.assertEqual(
            (self.app / MODULE.WEBCORE_MEDIA_CONTROLS_REVIEW_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBCORE_MEDIA_CONTROLS_REVIEW_SOURCE).read_bytes(),
        )
        self.assertEqual(
            result["webKitSourceCandidateManifestSHA256"],
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root
            )["webKitSourceCandidateManifestSHA256"],
        )
        self.assertEqual(
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)["licenseSHA256"],
            MODULE.LICENSE_SHA256,
        )
        markdown = (self.app / MODULE.NOTICE_DESTINATION).read_text(encoding="utf-8")
        html = (self.app / MODULE.HTML_DESTINATION).read_text(encoding="utf-8")
        self.assertIn(MODULE.SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBCORE_MEDIA_CONTROLS_SECTION_MARKER, markdown)
        self.assertIn("applicable license and required attribution remain UNKNOWN", markdown)
        self.assertNotIn("MediaControlsAssets-BSD-2-Clause", markdown)
        self.assertIn(MODULE.WEBCORE_MEDIA_CONTROLS_HTML_MARKER, html)
        self.assertIn(MODULE.WEBCORE_MODEL_IBL_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBCORE_MODEL_IBL_HTML_MARKER, html)
        self.assertIn("Applicable terms and attribution remain UNKNOWN", html)
        self.assertIn("separate source, notices, or relinking review", markdown)
        self.assertIn(MODULE.HTML_MARKER, html)
        self.assertIn(MODULE.LGPL2_SECTION_MARKER, markdown)
        self.assertIn(MODULE.JSC_COPYING_LIB_SECTION_MARKER, markdown)
        self.assertIn(MODULE.JSC_COPYING_LIB_HTML_MARKER, html)
        self.assertIn("Per-file scope", markdown)
        self.assertIn(MODULE.LGPL2_HTML_MARKER, html)
        self.assertIn(MODULE.LGPL21_SECTION_MARKER, markdown)
        self.assertIn(MODULE.LGPL21_HTML_MARKER, html)
        self.assertIn(MODULE.JSC_TRI_LICENSE_SECTION_MARKER, markdown)
        self.assertIn(MODULE.JSC_TRI_LICENSE_HTML_MARKER, html)
        self.assertIn(MODULE.JSC_UNICODE_SECTION_MARKER, markdown)
        self.assertIn(MODULE.JSC_UNICODE_HTML_MARKER, html)
        self.assertIn("CaseFolding.txt", markdown)
        self.assertIn("Unicode 17.0.0", markdown)
        self.assertIn(MODULE.JSC_GENERATED_LINEAGE_SHA256, markdown)
        self.assertIn("Source/JavaScriptCore/runtime/JSDateMath.cpp", markdown)
        self.assertIn("NeAntik applies the LGPL-2.1 option", markdown)
        self.assertIn("The original alternatives remain available to recipients", markdown)
        for source, _digest, destination in (
                (MODULE.JSC_UNICODE_LICENSE_SOURCE, MODULE.JSC_UNICODE_LICENSE_SHA256,
                 MODULE.JSC_UNICODE_LICENSE_DESTINATION),
                (MODULE.JSC_MPL11_SOURCE, MODULE.JSC_MPL11_SHA256,
                 MODULE.JSC_MPL11_DESTINATION),
                (MODULE.JSC_GPL2_SOURCE, MODULE.JSC_GPL2_SHA256,
                 MODULE.JSC_GPL2_DESTINATION)):
            self.assertEqual((self.app / destination).read_bytes(),
                             (self.root / source).read_bytes())
        self.assertEqual(
            (self.app / MODULE.JSC_GENERATED_LINEAGE_DESTINATION).read_bytes(),
            (self.root / MODULE.JSC_GENERATED_LINEAGE_SOURCE).read_bytes())
        self.assertIn(MODULE.ANGLE_SECTION_MARKER, markdown)
        self.assertIn(MODULE.ANGLE_HTML_MARKER, html)
        self.assertIn("xxHash", markdown)
        self.assertIn("ANGLE zlib compression helper symbols", markdown)
        self.assertIn(MODULE.WEBRTC_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBRTC_HTML_MARKER, html)
        self.assertIn(MODULE.LINKED_HEADERS_SECTION_MARKER, markdown)
        self.assertIn(MODULE.LINKED_HEADERS_HTML_MARKER, html)
        self.assertIn(MODULE.LINKED_HEADERS_MANIFEST_SHA256, markdown)
        self.assertIn("usage_exit_stub.c", markdown)
        self.assertIn(MODULE.WEBRTC_MPL2_SHA256, markdown)
        self.assertIn(MODULE.WEBRTC_MPL2_SHA256, html)
        self.assertEqual(
            (self.app / MODULE.WEBRTC_MPL2_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBRTC_MPL2_SOURCE).read_bytes(),
        )
        self.assertIn(MODULE.WEBINSPECTOR_FRAMEWORK_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBINSPECTOR_FRAMEWORK_HTML_MARKER, html)
        self.assertIn(MODULE.WEBKIT_XPC_ENTRYPOINT_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBKIT_XPC_ENTRYPOINT_HTML_MARKER, html)
        self.assertIn("It is not a framework-wide license determination", markdown)
        self.assertIn("This is not a framework-wide license determination", html)
        self.assertIn(MODULE.SANDBOX_SECTION_MARKER, markdown)
        self.assertIn(MODULE.SANDBOX_HTML_MARKER, html)
        self.assertIn(MODULE.SOURCE_CANDIDATE_SECTION_MARKER, markdown)
        self.assertIn(MODULE.SOURCE_CANDIDATE_HTML_MARKER, html)
        self.assertIn("Path association is not a decision", markdown)
        self.assertIn("not a complete runtime notice bundle", markdown)
        self.assertIn("not a complete runtime notice bundle", html)
        self.assertIn("Source notice files: 62", markdown)
        self.assertIn("aom_external_partition.h", markdown)
        self.assertIn("Alliance for Open Media Patent License notices", markdown)
        self.assertIn("aom_external_partition.h", html)
        self.assertIn(MODULE.WEBGPU_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBGPU_HTML_MARKER, html)
        self.assertIn(MODULE.WEBGPU_IMAGE_SHA256, markdown)
        self.assertIn(MODULE.WEBGPU_LICENSE_SHA256, markdown)
        self.assertIn(MODULE.JSC_HEADERLESS_BSD2_SECTION_MARKER, markdown)
        self.assertIn(MODULE.JSC_GENERATED_OUTPUT_SECTION_MARKER, markdown)
        self.assertIn(MODULE.JSC_GENERATED_OUTPUT_HTML_MARKER,
                      (self.app / MODULE.HTML_DESTINATION).read_text(encoding="utf-8"))
        generated_notice = self.app / MODULE.JSC_GENERATED_OUTPUT_DESTINATION_ROOT / "GeneratedOutputHeaders.txt"
        self.assertEqual(MODULE.sha256_file(generated_notice), MODULE.JSC_GENERATED_OUTPUT_HEADERS_SHA256)
        self.assertIn(MODULE.JSC_HEADERLESS_BSD2_HTML_MARKER, html)
        self.assertIn(MODULE.WEBCORE_POPOVER_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBCORE_POPOVER_HTML_MARKER, html)
        self.assertIn("Copyright (C) 2023 Tim Nguyen.", markdown)
        self.assertIn(MODULE.WEBCORE_COLORDATA_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBCORE_COLORDATA_HTML_MARKER, html)
        self.assertIn("Copyright (C) 2002 Darin Adler.", markdown)
        self.assertIn(MODULE.WEBCORE_CSS_GENERATED_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBCORE_CSS_GENERATED_HTML_MARKER, html)
        self.assertIn("does not infer a unique per-file rights holder", markdown)
        self.assertIn(
            "Copyright (C) 2005, 2006, 2007, 2008, 2009 Apple Inc.",
            (self.app / MODULE.WEBCORE_CSS_GENERATED_APPLE_LICENSE_DESTINATION)
            .read_text(encoding="utf-8"),
        )
        self.assertEqual(
            (self.app / MODULE.WEBCORE_CSS_GENERATED_APPLE_LICENSE_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBCORE_CSS_GENERATED_APPLE_LICENSE_SOURCE).read_bytes(),
        )
        self.assertIn("32 JavaScriptCore generator inputs", markdown)
        self.assertIn("Per-file copyright attribution and complete JavaScriptCore image terms remain open", markdown)
        self.assertEqual(
            (self.app / MODULE.LICENSE_DESTINATION).read_bytes(),
            (self.root / MODULE.LICENSE_SOURCE).read_bytes(),
        )
        self.assertEqual(
            (self.app / MODULE.WEBCORE_LGPL2_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBCORE_LGPL2_SOURCE).read_bytes(),
        )
        self.assertEqual(
            (self.app / MODULE.WEBCORE_LGPL21_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBCORE_LGPL21_SOURCE).read_bytes(),
        )
        self.assertEqual(
            (self.app / MODULE.WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE).read_bytes(),
        )
        self.assertEqual(
            (self.app / MODULE.WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION).read_bytes(),
            (self.root / MODULE.WEBKIT_XPC_ENTRYPOINT_NOTICE_SOURCE).read_bytes(),
        )
        for source, _name, expected_hash, destination in MODULE._angle_notice_sources(self.root):
            packaged = self.app / destination
            self.assertEqual(MODULE.sha256_file(packaged), expected_hash)
            self.assertEqual(packaged.read_bytes(), (self.root / source).read_bytes())
        manifest, notices = MODULE._webrtc_notice_sources(self.root)
        self.assertEqual(manifest["noticeFileCount"], 63)
        self.assertEqual(manifest["generatedThirdPartyIndex"]["sha256"],
                         "5060ec75dfac608d911b68b94fc6b8db95c93273469f954876c7be4c013bda14")
        self.assertIn("files/Source/ThirdParty/libwebrtc/Source/webrtc/LICENSE_THIRD_PARTY",
                      {row["path"] for row in manifest["notices"]})
        packaged_manifest = self.app / MODULE.WEBRTC_NOTICE_ROOT / "MANIFEST.json"
        self.assertEqual(packaged_manifest.read_bytes(),
                         (self.root / MODULE.WEBRTC_MANIFEST_SOURCE).read_bytes())
        self.assertEqual(len(notices), 62)
        libaom_rows = [row for row in manifest["notices"] if "libaom-header-notices" in row["path"]]
        self.assertEqual(len(libaom_rows), 3)
        for _source, output, expected_hash, size in notices:
            packaged = self.app / MODULE.WEBRTC_NOTICE_ROOT / output
            self.assertEqual(packaged.stat().st_size, size)
            self.assertEqual(MODULE.sha256_file(packaged), expected_hash)
        header_manifest, headers = MODULE._linked_source_header_notices(self.root)
        self.assertEqual([row["noticeEntryCount"] for row in header_manifest["images"]],
                         [906, 2028, 193])
        for (source, digest, size), row in zip(headers, header_manifest["images"]):
            packaged = self.app / MODULE.LINKED_HEADERS_DESTINATION_ROOT / row["noticePath"]
            self.assertEqual(packaged.stat().st_size, size)
            self.assertEqual(MODULE.sha256_file(packaged), digest)
            self.assertEqual(packaged.read_bytes(), source.read_bytes())
        for name, _source_path, _runtime_path, _size in MODULE._sandbox_notice_sources(self.root):
            packaged = self.app / MODULE.SANDBOX_NOTICE_ROOT / name
            self.assertEqual(packaged.read_bytes(),
                             (self.root / MODULE.SANDBOX_SOURCE_ROOT / name).read_bytes())
        manifest, _bytes, candidate_sources = MODULE._source_candidate_notice_sources(self.root)
        self.assertEqual(len(candidate_sources), 12)
        self.assertEqual(manifest["entryCount"], 12)
        for row, (_source_path, source, expected_hash, expected_size) in zip(
                manifest["entries"], candidate_sources):
            packaged = self.app / MODULE.SOURCE_CANDIDATE_NOTICE_ROOT / row["outputPath"]
            self.assertEqual(packaged.stat().st_size, expected_size)
            self.assertEqual(MODULE.sha256_file(packaged), expected_hash)
            self.assertEqual(packaged.read_bytes(), source.read_bytes())
        swift_manifest, swift_manifest_bytes, swift_headers = (
            MODULE._webkit_swift_source_notice_sources(self.root))
        packaged_swift_root = self.app / MODULE.WEBKIT_SWIFT_NOTICE_ROOT
        self.assertEqual((packaged_swift_root / "MANIFEST.json").read_bytes(),
                         swift_manifest_bytes)
        self.assertEqual(len(swift_headers), 32)
        self.assertEqual(swift_manifest["entryCount"], 32)
        for row, (source_path, source, expected_hash, expected_size) in zip(
                swift_manifest["entries"], swift_headers):
            packaged = packaged_swift_root / row["outputPath"]
            self.assertEqual(source_path, row["sourcePath"])
            self.assertEqual(packaged.stat().st_size, expected_size)
            self.assertEqual(MODULE.sha256_file(packaged), expected_hash)
            self.assertEqual(packaged.read_bytes(), source.read_bytes())

    def test_corrupt_sandbox_source_fails_before_notice_write(self):
        name = MODULE._sandbox_notice_sources(self.root)[0][0]
        source = self.root / MODULE.SANDBOX_SOURCE_ROOT / name
        source.write_bytes(source.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "sandbox source hash/size mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.SANDBOX_NOTICE_ROOT / "MANIFEST.json").exists())

    def test_corrupt_source_crosswalk_fails_before_notice_write(self):
        crosswalk = self.root / MODULE.SOURCE_CROSSWALK
        crosswalk.write_bytes(crosswalk.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "crosswalk SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.SOURCE_CANDIDATE_NOTICE_ROOT / "MANIFEST.json").exists())

    def test_corrupt_webkitswift_header_fails_before_notice_write(self):
        _manifest, _manifest_bytes, headers = MODULE._webkit_swift_source_notice_sources(self.root)
        source = headers[0][1]
        source.write_bytes(source.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "source-header hash/size mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBKIT_SWIFT_NOTICE_ROOT / "MANIFEST.json").exists())

    def test_corrupt_webkit_xpc_source_notice_fails_before_notice_write(self):
        source = self.root / MODULE.WEBKIT_XPC_ENTRYPOINT_NOTICE_SOURCE
        source.write_bytes(source.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError,
                                    "pinned WebKit XPC entrypoint BSD notice SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION).exists())

    def test_corrupt_packaged_webkitswift_header_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        _manifest, _manifest_bytes, headers = MODULE._webkit_swift_source_notice_sources(self.root)
        packaged = self.app / MODULE.WEBKIT_SWIFT_NOTICE_ROOT / headers[0][1].relative_to(
            self.root / MODULE.WEBKIT_SWIFT_SOURCE_NOTICE_ROOT)
        packaged.write_bytes(packaged.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged WebKitSwift source header differs"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_webkitswift_runtime_images_are_hash_and_macho_bound(self):
        runtime = self.root / "RuntimeFrameworks"
        image_path = Path("WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib")
        image = runtime / image_path
        image.parent.mkdir(parents=True)
        image.write_bytes(bytes.fromhex("cffaedfe") + b"exact runtime")
        digest = MODULE.sha256_file(image)
        manifest = {"runtimeImages": [{"path": image_path.as_posix(), "sha256": digest}]}
        self.real_runtime_image_check(runtime, manifest)
        manifest["runtimeImages"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(MODULE.NoticeError, "runtime image SHA-256 mismatch"):
            self.real_runtime_image_check(runtime, manifest)

    def test_recipient_signed_runtime_image_uses_exact_binding(self):
        runtime = self.root / "RecipientFrameworks"
        relative = Path("JavaScriptCore.framework/Versions/A/JavaScriptCore")
        image = runtime / relative
        image.parent.mkdir(parents=True)
        image.write_bytes(bytes.fromhex("cffaedfe") + b"recipient-signed image")
        actual = MODULE.sha256_file(image)
        expected_source = "1" * 64
        binding = runtime / MODULE.RUNTIME_IMAGE_BINDING_FILE
        binding.write_text(json.dumps({
            "schemaVersion": 1,
            "status": "recipient-signed-runtime-image-binding",
            "imageCount": 1,
            "images": [{
                "path": relative.as_posix(),
                "sourceInputSHA256": expected_source,
                "relocatedSHA256": "2" * 64,
                "recipientSignedSHA256": actual,
                "rpathChange": {"remove": [], "add": "@loader_path/../../.."},
            }],
        }))
        self.assertEqual(MODULE._runtime_image_build_sha(runtime, relative, expected_source),
                         expected_source)
        binding.write_text(binding.read_text().replace(actual, "3" * 64))
        with self.assertRaisesRegex(MODULE.NoticeError, "runtime image SHA-256 mismatch"):
            MODULE._runtime_image_build_sha(runtime, relative, expected_source)

    def test_unbound_signed_image_cannot_claim_pinned_source_hash(self):
        runtime = self.root / "UnboundFrameworks"
        relative = Path("JavaScriptCore.framework/Versions/A/JavaScriptCore")
        image = runtime / relative
        image.parent.mkdir(parents=True)
        image.write_bytes(bytes.fromhex("cffaedfe") + b"signed but unbound")
        with self.assertRaisesRegex(MODULE.NoticeError, "runtime image SHA-256 mismatch"):
            MODULE._runtime_image_build_sha(runtime, relative, "1" * 64)

    def test_corrupt_packaged_sandbox_source_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        name = MODULE._sandbox_notice_sources(self.root)[0][0]
        packaged = self.app / MODULE.SANDBOX_NOTICE_ROOT / name
        packaged.write_bytes(packaged.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged WebKit sandbox source differs"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_webrtc_notice_fails_before_any_notice_write(self):
        _manifest, notices = MODULE._webrtc_notice_sources(self.root)
        first = self.root / MODULE.WEBRTC_CANDIDATE_ROOT / notices[0][1]
        first.write_bytes(first.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "source hash/size mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBRTC_NOTICE_ROOT / "MANIFEST.json").exists())

    def test_corrupt_jsc_alternative_license_source_fails_before_notice_write(self):
        source = self.root / MODULE.JSC_MPL11_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "JavaScriptCore license text SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.JSC_MPL11_DESTINATION).exists())

    def test_corrupt_unicode_license_source_fails_before_notice_write(self):
        source = self.root / MODULE.JSC_UNICODE_LICENSE_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "Unicode License v3 SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.JSC_UNICODE_LICENSE_DESTINATION).exists())

    def test_corrupt_jsc_lineage_receipt_fails_before_notice_write(self):
        source = self.root / MODULE.JSC_GENERATED_LINEAGE_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError,
                                    "generated-input lineage SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.JSC_GENERATED_LINEAGE_DESTINATION).exists())

    def test_corrupt_jsc_headerless_terms_review_fails_before_notice_write(self):
        source = self.root / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError,
                                    "headerless-input review SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.JSC_HEADERLESS_BSD2_REVIEW_DESTINATION).exists())

    def test_corrupt_packaged_jsc_headerless_bsd2_notice_inputs_are_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.JSC_HEADERLESS_BSD2_LICENSE_DESTINATION).write_bytes(b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError,
                                    "packaged JavaScriptCore BSD-2 text differs"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_jsc_generated_output_headers_are_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        packaged = (self.app / MODULE.JSC_GENERATED_OUTPUT_DESTINATION_ROOT
                    / "GeneratedOutputHeaders.txt")
        packaged.write_bytes(packaged.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError,
                                    "packaged JavaScriptCore generated-output headers"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_unicode_lineage_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.JSC_GENERATED_LINEAGE_DESTINATION).write_bytes(b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError,
                                    "packaged JavaScriptCore generated-input lineage"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_jsc_alternative_license_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.JSC_GPL2_DESTINATION).write_bytes(b"wrong license")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged JavaScriptCore license differs"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_mpl2_source_fails_before_any_notice_write(self):
        source = self.root / MODULE.WEBRTC_MPL2_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "MPL-2.0 license SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBRTC_MPL2_DESTINATION).exists())

    def test_corrupt_linked_header_source_fails_before_any_notice_write(self):
        manifest, _ = MODULE._linked_source_header_notices(self.root)
        source = (self.root / MODULE.LINKED_HEADERS_SOURCE_ROOT
                  / manifest["images"][0]["noticePath"])
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "linked source-header notice hash/size mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.LINKED_HEADERS_DESTINATION_ROOT
                          / "MANIFEST.json").exists())

    def test_corrupt_webcore_generated_header_source_fails_before_notice_write(self):
        source = self.root / MODULE.WEBCORE_GENERATED_HEADERS_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "generated-input headers SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBCORE_GENERATED_HEADERS_DESTINATION).exists())

    def test_corrupt_webrtc_generated_header_source_fails_before_notice_write(self):
        source = self.root / MODULE.WEBRTC_GENERATED_HEADERS_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "libwebrtc generated-input headers SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBRTC_GENERATED_HEADERS_DESTINATION).exists())

    def test_symlinked_webrtc_notice_is_rejected(self):
        _manifest, notices = MODULE._webrtc_notice_sources(self.root)
        first = self.root / MODULE.WEBRTC_CANDIDATE_ROOT / notices[0][1]
        copy = first.with_suffix(first.suffix + ".copy")
        shutil.copyfile(first, copy)
        first.unlink()
        first.symlink_to(copy)
        with self.assertRaisesRegex(MODULE.NoticeError, "must not traverse a symlink"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBRTC_NOTICE_ROOT / "MANIFEST.json").exists())

    def test_missing_webrtc_runtime_image_fails_before_notice_write(self):
        self.webrtc_library.unlink()
        with self.assertRaisesRegex(MODULE.NoticeError, "exactly one bundled libwebrtc"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.WEBRTC_NOTICE_ROOT / "MANIFEST.json").exists())

    def test_corrupt_packaged_webrtc_notice_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        _manifest, notices = MODULE._webrtc_notice_sources(self.root)
        packaged = self.app / MODULE.WEBRTC_NOTICE_ROOT / notices[0][1]
        packaged.write_bytes(packaged.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged WebRTC notice hash/size mismatch"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_mpl2_text_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.WEBRTC_MPL2_DESTINATION
        packaged.write_bytes(packaged.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged WebRTC shim MPL-2.0 text"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_linked_header_notice_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        manifest, _ = MODULE._linked_source_header_notices(self.root)
        packaged = (self.app / MODULE.LINKED_HEADERS_DESTINATION_ROOT
                    / manifest["images"][0]["noticePath"])
        packaged.write_bytes(packaged.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged linked source-header notice"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_webcore_generated_headers_are_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.WEBCORE_GENERATED_HEADERS_DESTINATION
        packaged.write_bytes(packaged.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged WebCore generated-input headers"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_webrtc_generated_headers_are_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.WEBRTC_GENERATED_HEADERS_DESTINATION
        packaged.write_bytes(packaged.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged libwebrtc generated-input headers"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_missing_angle_image_fails_before_any_notice_write(self):
        self.angle_library.unlink()
        with self.assertRaisesRegex(MODULE.NoticeError, "exactly one bundled libANGLE"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.ANGLE_LICENSE_DESTINATION).exists())

    def test_symlinked_angle_image_is_rejected_even_when_a_regular_copy_exists(self):
        other = self.frameworks / "other"
        other.mkdir()
        (other / "libANGLE-shared.dylib").symlink_to(self.angle_library)
        with self.assertRaisesRegex(MODULE.NoticeError, "must not be a symlink"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.ANGLE_LICENSE_DESTINATION).exists())

    def test_corrupt_angle_license_fails_before_any_notice_write(self):
        source = self.root / MODULE.ANGLE_LICENSE_SOURCE
        source.write_bytes(source.read_bytes() + b"tampered")
        with self.assertRaisesRegex(MODULE.NoticeError, "license SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.ANGLE_LICENSE_DESTINATION).exists())

    def test_runtime_byte_change_invalidates_the_notice_hash(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        self.library.write_bytes(self.library.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "Markdown notice does not match"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_generated_html_fragment_without_closing_body_accepts_notice_at_eof(self):
        html_path = self.app / MODULE.HTML_DESTINATION
        source = "<!doctype html><html><body><h1>Chromium notices</h1>\n"
        html_path.write_text(source, encoding="utf-8")
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        result = html_path.read_text(encoding="utf-8")
        self.assertTrue(result.startswith(source))
        self.assertTrue(result.rstrip().endswith("</section>"))
        self.assertIn(MODULE.HTML_MARKER, result)

    def test_html_without_a_body_is_still_rejected(self):
        html_path = self.app / MODULE.HTML_DESTINATION
        html_path.write_text("<!doctype html><html><h1>not a body</h1></html>", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.NoticeError, "no body element"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_license_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.LICENSE_DESTINATION).write_bytes(b"wrong license")
        with self.assertRaisesRegex(MODULE.NoticeError, "license SHA-256 mismatch"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_webgpu_adapter_header_is_packaged_and_tampering_rejected(self):
        MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.WEBGPU_ADAPTER_HEADER_DESTINATION
        self.assertEqual(packaged.read_bytes(), (self.root / MODULE.WEBGPU_ADAPTER_HEADER_SOURCE).read_bytes())
        self.assertIn('WebGPU-Adapter-Source-Header.txt', (self.app / MODULE.NOTICE_DESTINATION).read_text())
        self.assertIn('WebGPU-Adapter-Source-Header.txt', (self.app / MODULE.HTML_DESTINATION).read_text())
        packaged.write_bytes(b'tampered')
        with self.assertRaisesRegex(MODULE.NoticeError, 'packaged WebGPU Adapter source header'):
            MODULE.verify_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)

    def test_webgpu_adapter_source_tampering_is_rejected_before_notice_write(self):
        source = self.root / MODULE.WEBGPU_ADAPTER_HEADER_SOURCE
        source.write_bytes(b'tampered')
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, 'WebGPU Adapter source header hash/size mismatch'):
            MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_dav1d_headers_are_packaged_and_tampering_is_rejected(self):
        MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.DAV1D_HEADERS_DESTINATION
        self.assertEqual(packaged.read_bytes(), (self.root / MODULE.DAV1D_HEADERS_SOURCE).read_bytes())
        self.assertIn('dav1d-source-header-supplement.txt', (self.app / MODULE.NOTICE_DESTINATION).read_text())
        self.assertIn('dav1d-source-header-supplement.txt', (self.app / MODULE.HTML_DESTINATION).read_text())
        packaged.write_bytes(b'tampered')
        with self.assertRaisesRegex(MODULE.NoticeError, 'packaged dav1d source headers'):
            MODULE.verify_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)

    def test_dav1d_source_tampering_is_rejected_before_notice_write(self):
        source = self.root / MODULE.DAV1D_HEADERS_SOURCE
        source.write_bytes(b'tampered')
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, 'dav1d source headers hash/size mismatch'):
            MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_rnnoise_header_is_packaged_and_tampering_is_rejected(self):
        MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.RNNOISE_HEADER_DESTINATION
        self.assertEqual(packaged.read_bytes(), (self.root / MODULE.RNNOISE_HEADER_SOURCE).read_bytes())
        self.assertIn('rnn-activations-header.txt', (self.app / MODULE.NOTICE_DESTINATION).read_text())
        self.assertIn('rnn-activations-header.txt', (self.app / MODULE.HTML_DESTINATION).read_text())
        packaged.write_bytes(b'tampered')
        with self.assertRaisesRegex(MODULE.NoticeError, 'packaged rnnoise source header'):
            MODULE.verify_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)

    def test_rnnoise_source_tampering_is_rejected_before_notice_write(self):
        source = self.root / MODULE.RNNOISE_HEADER_SOURCE
        source.write_bytes(b'tampered')
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, 'rnnoise source header hash/size mismatch'):
            MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_libsrtp_headers_are_packaged_and_tampering_is_rejected(self):
        MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.LIBSRTP_HEADERS_DESTINATION
        self.assertEqual(packaged.read_bytes(), (self.root / MODULE.LIBSRTP_HEADERS_SOURCE).read_bytes())
        self.assertIn('libsrtp/source-headers.txt', (self.app / MODULE.NOTICE_DESTINATION).read_text())
        self.assertIn('libsrtp/source-headers.txt', (self.app / MODULE.HTML_DESTINATION).read_text())
        packaged.write_bytes(b'tampered')
        with self.assertRaisesRegex(MODULE.NoticeError, 'packaged libsrtp source headers'):
            MODULE.verify_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)

    def test_libsrtp_source_tampering_is_rejected_before_notice_write(self):
        source = self.root / MODULE.LIBSRTP_HEADERS_SOURCE
        source.write_bytes(b'tampered')
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, 'libsrtp source headers hash/size mismatch'):
            MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_opus_headers_are_packaged_and_tampering_is_rejected(self):
        MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.OPUS_HEADERS_DESTINATION
        self.assertEqual(packaged.read_bytes(), (self.root / MODULE.OPUS_HEADERS_SOURCE).read_bytes())
        self.assertIn('opus/source-headers.txt', (self.app / MODULE.NOTICE_DESTINATION).read_text())
        self.assertIn('opus/source-headers.txt', (self.app / MODULE.HTML_DESTINATION).read_text())
        packaged.write_bytes(b'tampered')
        with self.assertRaisesRegex(MODULE.NoticeError, 'packaged Opus source headers'):
            MODULE.verify_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)

    def test_opus_source_tampering_is_rejected_before_notice_write(self):
        source = self.root / MODULE.OPUS_HEADERS_SOURCE
        source.write_bytes(b'tampered')
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, 'Opus source headers hash/size mismatch'):
            MODULE.install_owned_webkit_notices(self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_corrupt_pinned_lgpl2_source_is_rejected_before_packaging(self):
        source = self.root / MODULE.WEBCORE_LGPL2_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "WebCore LGPL-2 license SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_jsc_copying_lib_source_is_rejected_before_notice_write(self):
        source = self.root / MODULE.JSC_COPYING_LIB_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, "JavaScriptCore COPYING.LIB SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_corrupt_packaged_jsc_copying_lib_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.JSC_COPYING_LIB_DESTINATION).write_bytes(b"wrong license")
        with self.assertRaisesRegex(MODULE.NoticeError, "packaged JavaScriptCore COPYING.LIB"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_jsc_binja_attribution_source_is_rejected_before_notice_write(self):
        source = self.root / MODULE.JSC_BINJA_ATTRIBUTION_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        before = (self.app / MODULE.NOTICE_DESTINATION).read_bytes()
        with self.assertRaisesRegex(MODULE.NoticeError, "Binary Ninja attribution SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertEqual((self.app / MODULE.NOTICE_DESTINATION).read_bytes(), before)

    def test_corrupt_packaged_jsc_binja_apache_license_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.JSC_BINJA_APACHE_DESTINATION).write_bytes(b"wrong license")
        with self.assertRaisesRegex(MODULE.NoticeError, "Binary Ninja Apache license"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_lgpl2_text_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.WEBCORE_LGPL2_DESTINATION).write_bytes(b"wrong license")
        with self.assertRaisesRegex(MODULE.NoticeError, "WebCore LGPL-2 license SHA-256 mismatch"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_pinned_lgpl21_source_is_rejected_before_packaging(self):
        source = self.root / MODULE.WEBCORE_LGPL21_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "WebCore LGPL-2.1 license SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_webgpu_runtime_change_invalidates_the_notice_binding(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        self.webgpu_image.write_bytes(bytes.fromhex("cffaedfe") + b"changed WebGPU Mach-O")
        with self.assertRaisesRegex(MODULE.NoticeError, "WebGPU runtime image SHA-256 mismatch"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_corrupt_packaged_lgpl21_text_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        (self.app / MODULE.WEBCORE_LGPL21_DESTINATION).write_bytes(b"wrong license")
        with self.assertRaisesRegex(MODULE.NoticeError, "WebCore LGPL-2.1 license SHA-256 mismatch"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_existing_owned_notices_are_replaced_idempotently(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        first_markdown = (self.app / MODULE.NOTICE_DESTINATION).read_text(encoding="utf-8")
        first_html = (self.app / MODULE.HTML_DESTINATION).read_text(encoding="utf-8")
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        current_markdown = (self.app / MODULE.NOTICE_DESTINATION).read_text(encoding="utf-8")
        current_html = (self.app / MODULE.HTML_DESTINATION).read_text(encoding="utf-8")
        for marker in MODULE.OWNED_MARKDOWN_MARKERS:
            expected = 0 if marker in {
                MODULE.WEBCORE_FIRST_PARTY_SECTION_MARKER,
                MODULE.WEBKIT_WARNING_COLOR_SECTION_MARKER,
            } else 1
            self.assertEqual(current_markdown.splitlines().count(marker), expected)
        for marker in MODULE.OWNED_HTML_MARKERS:
            expected = 0 if marker in {
                MODULE.WEBCORE_FIRST_PARTY_HTML_MARKER,
                MODULE.WEBKIT_WARNING_COLOR_HTML_MARKER,
            } else 1
            self.assertEqual(current_html.count(marker), expected)
        self.assertEqual(current_markdown, first_markdown)
        self.assertEqual(current_html, first_html)
        markdown = self.app / MODULE.NOTICE_DESTINATION
        current = markdown.read_text(encoding="utf-8")
        old_hash = MODULE.sha256_file(self.library)
        markdown.write_text(current.replace(old_hash, "b" * 64), encoding="utf-8")
        with self.assertRaisesRegex(MODULE.NoticeError, "Markdown notice does not match"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_duplicate_owned_markdown_marker_refuses_before_package_writes(self):
        markdown = self.app / MODULE.NOTICE_DESTINATION
        markdown.write_text(
            markdown.read_text(encoding="utf-8") + "\n"
            + MODULE.SECTION_MARKER + "\n" + MODULE.SECTION_MARKER + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(MODULE.NoticeError, "duplicate owned-WebKit Markdown marker"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.LICENSE_DESTINATION).exists())

    def test_unterminated_owned_html_section_refuses_before_package_writes(self):
        html_path = self.app / MODULE.HTML_DESTINATION
        html_path.write_text(
            html_path.read_text(encoding="utf-8") + MODULE.HTML_MARKER,
            encoding="utf-8",
        )
        with self.assertRaisesRegex(MODULE.NoticeError, "unterminated owned-WebKit HTML section"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.LICENSE_DESTINATION).exists())

    def test_symlinked_license_destination_is_rejected(self):
        license_dir = self.app / MODULE.LICENSE_DESTINATION.parent
        license_dir.mkdir(parents=True)
        target = self.root / "outside-license"
        target.write_bytes(b"outside")
        (license_dir / MODULE.LICENSE_NAME).symlink_to(target)
        with self.assertRaisesRegex(MODULE.NoticeError, "must not be a symlink"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_missing_or_non_macho_compatibility_library_is_rejected(self):
        self.library.unlink()
        with self.assertRaisesRegex(MODULE.NoticeError, "exactly one bundled"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.library.write_bytes(b"not a Mach-O")
        with self.assertRaisesRegex(MODULE.NoticeError, "not a Mach-O"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_changed_webinspector_resource_is_rejected_before_package_writes(self):
        resource = (self.frameworks / "WebInspectorUI.framework/Versions/A/Resources/External"
                    / "CodeMirror/LICENSE")
        resource.write_bytes(b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "bundled WebInspectorUI license hash/size mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse((self.app / MODULE.LICENSE_DESTINATION).exists())

    def test_corrupt_webinspector_framework_license_is_rejected_before_writes(self):
        source = self.root / MODULE.WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(
                MODULE.NoticeError,
                "pinned WebInspectorUI framework license SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)
        self.assertFalse(
            (self.app / MODULE.WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION).exists())

    def test_corrupt_packaged_webinspector_framework_license_is_rejected(self):
        MODULE.install_owned_webkit_notices(
            self.app, self.frameworks, project_root=self.root)
        packaged = self.app / MODULE.WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION
        packaged.write_bytes(b"wrong license")
        with self.assertRaisesRegex(
                MODULE.NoticeError,
                "packaged WebInspectorUI framework source notice differs"):
            MODULE.verify_owned_webkit_notices(
                self.app, self.frameworks, project_root=self.root)

    def test_filtered_model_runtime_absence_is_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            frameworks.mkdir()
            paths = (
                "WebKit.framework/Versions/A/Resources/TextExtractionFilter.mlmodelc/analytics/coremldata.bin",
                "WebKit.framework/Versions/A/Resources/TextExtractionFilter.mlmodelc/coremldata.bin",
                "WebKit.framework/Versions/A/Resources/TextExtractionFilter.mlmodelc/metadata.json",
                "WebKit.framework/Versions/A/Resources/corePrediction_model",
            )
            crosswalk = {"excludedRuntimeRows": {
                "sourceRows": [{"runtimePath": path} for path in paths]}}
            MODULE._verify_excluded_model_runtime_absence(frameworks, crosswalk)
            unexpected = frameworks / paths[0]
            unexpected.parent.mkdir(parents=True)
            unexpected.write_bytes(b"model output")
            with self.assertRaisesRegex(MODULE.NoticeError, "resource is present"):
                MODULE._verify_excluded_model_runtime_absence(frameworks, crosswalk)


if __name__ == "__main__":
    unittest.main()
