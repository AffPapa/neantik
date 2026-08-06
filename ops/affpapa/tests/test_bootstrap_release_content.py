import json
import plistlib
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
CONTENT = ROOT / "ops" / "affpapa" / "bootstrap" / "content.json"
TEMPLATE = ROOT / "ops" / "affpapa" / "bootstrap" / "neantik.blade.php"
INFO_PLIST = ROOT / "Resources" / "Info.plist"
RUNTIME_LOCK = ROOT / "runtime" / "fingerprint-chromium.lock.json"


class BootstrapReleaseContentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.content = json.loads(CONTENT.read_text(encoding="utf-8"))
        with INFO_PLIST.open("rb") as file:
            self.info = plistlib.load(file)
        self.runtime_lock = json.loads(
            RUNTIME_LOCK.read_text(encoding="utf-8")
        )
        self.template = TEMPLATE.read_text(encoding="utf-8")

    def test_bootstrap_content_tracks_current_source_release(self) -> None:
        version = str(self.info["CFBundleShortVersionString"])
        build = int(self.info["CFBundleVersion"])
        latest = self.content["changelog"][0]

        self.assertEqual(self.content["releaseVersion"], version)
        self.assertEqual(latest["version"], version)
        self.assertEqual(latest["build"], build)
        self.assertTrue(latest["items"])

    def test_template_fallback_tracks_current_source_release(self) -> None:
        version = str(self.info["CFBundleShortVersionString"])
        build = int(self.info["CFBundleVersion"])
        runtime = str(
            self.runtime_lock["fingerprintChromium"]["chromiumVersion"]
        )

        self.assertIn(
            f"$releaseManifest['version'] ?? '{version}'",
            self.template,
        )
        self.assertIn(
            f"$releaseManifest['build'] ?? {build}",
            self.template,
        )
        self.assertIn(
            f"$releaseManifest['runtime']['version'] ?? '{runtime}'",
            self.template,
        )
        self.assertIn(f"'ver' => '{version}'", self.template)
        self.assertIn(f"'build' => {build}", self.template)


if __name__ == "__main__":
    unittest.main()
