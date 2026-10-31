import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "webkit_runtime_notices.py"
SPEC = importlib.util.spec_from_file_location("libwebm_authors_supplement", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PROJECT_ROOT = SCRIPT.parents[1]


class LibwebmAuthorsSupplementTests(unittest.TestCase):
    def test_source_and_packaged_bytes_are_required_and_symlinks_refused(self):
        original = PROJECT_ROOT / MODULE.WEBRTC_LIBWEBM_AUTHORS_SOURCE
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / MODULE.WEBRTC_LIBWEBM_AUTHORS_SOURCE
            source.parent.mkdir(parents=True)
            with self.assertRaises(MODULE.NoticeError):
                MODULE._webrtc_libwebm_authors(root)
            shutil.copyfile(original, source)
            checked = MODULE._webrtc_libwebm_authors(root)
            app = root / "NeAntik.app"
            app.mkdir()
            packaged = MODULE._safe_destination(
                app, MODULE.WEBRTC_LIBWEBM_AUTHORS_DESTINATION, create_parent=True)
            shutil.copyfile(checked, packaged)
            MODULE._verify_packaged_libwebm_authors(app, checked)
            packaged.write_bytes(b"altered")
            with self.assertRaises(MODULE.NoticeError):
                MODULE._verify_packaged_libwebm_authors(app, checked)
            packaged.unlink()
            packaged.symlink_to(checked)
            with self.assertRaises(MODULE.NoticeError):
                MODULE._verify_packaged_libwebm_authors(app, checked)
            source.unlink()
            source.symlink_to(original)
            with self.assertRaises(MODULE.NoticeError):
                MODULE._webrtc_libwebm_authors(root)

    def test_both_notice_formats_identify_supplement_without_changing_manifest_count(self):
        manifest = {"upstream": {"sha256": "a" * 64}}
        for rendered in (MODULE.render_webrtc_markdown("b" * 64, manifest, ()),
                         MODULE.render_webrtc_html("b" * 64, manifest, ())):
            self.assertIn("supplements/libwebm/AUTHORS.TXT", rendered)
            self.assertIn(MODULE.WEBRTC_LIBWEBM_AUTHORS_SHA256, rendered)
            self.assertIn("Source notice files: 0", rendered)


if __name__ == "__main__":
    unittest.main()
