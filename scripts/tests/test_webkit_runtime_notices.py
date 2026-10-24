import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "webkit_runtime_notices.py"
SPEC = importlib.util.spec_from_file_location("webkit_runtime_notices", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ROOT = SCRIPT.parents[1]


class WebKitRuntimeNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "runtime/licenses").mkdir(parents=True)
        shutil.copyfile(
            ROOT / MODULE.LICENSE_SOURCE,
            self.root / MODULE.LICENSE_SOURCE,
        )
        lgpl2_source = self.root / MODULE.WEBCORE_LGPL2_SOURCE
        lgpl2_source.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / MODULE.WEBCORE_LGPL2_SOURCE, lgpl2_source)
        shutil.copyfile(ROOT / MODULE.WEBCORE_LGPL21_SOURCE,
                        self.root / MODULE.WEBCORE_LGPL21_SOURCE)
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
            ROOT / MODULE.SANDBOX_SOURCE_ROOT,
            self.root / MODULE.SANDBOX_SOURCE_ROOT,
        )
        crosswalk = self.root / MODULE.SOURCE_CROSSWALK
        crosswalk.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / MODULE.SOURCE_CROSSWALK, crosswalk)
        shutil.copytree(ROOT / MODULE.SOURCE_CORPUS_ROOT,
                        self.root / MODULE.SOURCE_CORPUS_ROOT)
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
        self.library = self.frameworks / "libswiftCompatibilitySpan.dylib"
        self.library.write_bytes(bytes.fromhex("cffaedfe") + b"test Mach-O")
        self.angle_library = self.frameworks / "libANGLE-shared.dylib"
        self.angle_library.write_bytes(bytes.fromhex("cffaedfe") + b"test ANGLE Mach-O")
        self.webrtc_library = self.frameworks / "libwebrtc.dylib"
        self.webrtc_library.write_bytes(bytes.fromhex("cffaedfe") + b"test WebRTC Mach-O")
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
        compliance_manifest = json.loads((self.app / "Contents/Resources/NeAntikRuntimeCompliance/compliance-manifest.json").read_text())
        self.assertEqual(compliance_manifest["notices"]["sha256"],
                         MODULE.sha256_file(self.app / MODULE.HTML_DESTINATION))
        self.assertEqual(result["licenseSHA256"], MODULE.LICENSE_SHA256)
        self.assertEqual(result["webcoreLGPL2SHA256"], MODULE.WEBCORE_LGPL2_SHA256)
        self.assertEqual(result["webcoreLGPL21SHA256"], MODULE.WEBCORE_LGPL21_SHA256)
        self.assertEqual(result["angleRuntimeSHA256"], MODULE.sha256_file(self.angle_library))
        self.assertEqual(result["angleLicenseSHA256"], MODULE.ANGLE_LICENSE_SHA256)
        self.assertEqual(result["xxhashLicenseSHA256"], MODULE.XXHASH_LICENSE_SHA256)
        self.assertEqual(result["webrtcRuntimeSHA256"], MODULE.sha256_file(self.webrtc_library))
        self.assertEqual(result["webrtcManifestSHA256"], MODULE.WEBRTC_MANIFEST_SHA256)
        self.assertEqual(result["webrtcNoticeCount"], "36")
        self.assertEqual(result["webInspectorExternalLicenseCount"], "4")
        self.assertEqual(result["webKitSandboxSourceNoticeCount"], "6")
        self.assertEqual(result["webKitSourceCandidateNoticeCount"], "12")
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
        self.assertIn("separate source, notices, or relinking review", markdown)
        self.assertIn(MODULE.HTML_MARKER, html)
        self.assertIn(MODULE.LGPL2_SECTION_MARKER, markdown)
        self.assertIn("Per-file scope", markdown)
        self.assertIn(MODULE.LGPL2_HTML_MARKER, html)
        self.assertIn(MODULE.LGPL21_SECTION_MARKER, markdown)
        self.assertIn(MODULE.LGPL21_HTML_MARKER, html)
        self.assertIn(MODULE.ANGLE_SECTION_MARKER, markdown)
        self.assertIn(MODULE.ANGLE_HTML_MARKER, html)
        self.assertIn("xxHash", markdown)
        self.assertIn("ANGLE zlib compression helper symbols", markdown)
        self.assertIn(MODULE.WEBRTC_SECTION_MARKER, markdown)
        self.assertIn(MODULE.WEBRTC_HTML_MARKER, html)
        self.assertIn(MODULE.SANDBOX_SECTION_MARKER, markdown)
        self.assertIn(MODULE.SANDBOX_HTML_MARKER, html)
        self.assertIn(MODULE.SOURCE_CANDIDATE_SECTION_MARKER, markdown)
        self.assertIn(MODULE.SOURCE_CANDIDATE_HTML_MARKER, html)
        self.assertIn("Path association is not a decision", markdown)
        self.assertIn("not a complete runtime notice bundle", markdown)
        self.assertIn("not a complete runtime notice bundle", html)
        self.assertIn("Source notice files: 36", markdown)
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
        for source, _name, expected_hash, destination in MODULE._angle_notice_sources(self.root):
            packaged = self.app / destination
            self.assertEqual(MODULE.sha256_file(packaged), expected_hash)
            self.assertEqual(packaged.read_bytes(), (self.root / source).read_bytes())
        manifest, notices = MODULE._webrtc_notice_sources(self.root)
        packaged_manifest = self.app / MODULE.WEBRTC_NOTICE_ROOT / "MANIFEST.json"
        self.assertEqual(packaged_manifest.read_bytes(),
                         (self.root / MODULE.WEBRTC_MANIFEST_SOURCE).read_bytes())
        self.assertEqual(len(notices), manifest["noticeCount"])
        for _source, output, expected_hash, size in notices:
            packaged = self.app / MODULE.WEBRTC_NOTICE_ROOT / output
            self.assertEqual(packaged.stat().st_size, size)
            self.assertEqual(MODULE.sha256_file(packaged), expected_hash)
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

    def test_corrupt_pinned_lgpl2_source_is_rejected_before_packaging(self):
        source = self.root / MODULE.WEBCORE_LGPL2_SOURCE
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(MODULE.NoticeError, "WebCore LGPL-2 license SHA-256 mismatch"):
            MODULE.install_owned_webkit_notices(
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
            self.assertEqual(current_markdown.splitlines().count(marker), 1)
        for marker in MODULE.OWNED_HTML_MARKERS:
            self.assertEqual(current_html.count(marker), 1)
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


if __name__ == "__main__":
    unittest.main()
