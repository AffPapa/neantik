import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
CONTENT = ROOT / "ops" / "affpapa" / "bootstrap" / "content.json"
TEMPLATE = ROOT / "ops" / "affpapa" / "bootstrap" / "neantik.blade.php"
RELEASES = ROOT / "releases"


class BootstrapReleaseContentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.content = json.loads(CONTENT.read_text(encoding="utf-8"))
        self.public_release = json.loads(
            (
                RELEASES
                / f"v{self.content['releaseVersion']}.json"
            ).read_text(encoding="utf-8")
        )
        self.template = TEMPLATE.read_text(encoding="utf-8")

    def test_bootstrap_content_tracks_published_release_snapshot(self) -> None:
        version = str(self.public_release["version"])
        build = int(self.public_release["build"])
        latest = self.content["changelog"][0]

        self.assertEqual(self.content["releaseVersion"], version)
        self.assertEqual(latest["version"], version)
        self.assertEqual(latest["build"], build)
        self.assertTrue(latest["items"])

    def test_template_fallback_tracks_published_release_snapshot(self) -> None:
        version = str(self.public_release["version"])
        build = int(self.public_release["build"])
        runtime = str(self.public_release["runtime"]["chromiumVersion"])

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

    def test_landing_keeps_release_audit_out_of_the_user_flow(self) -> None:
        self.assertNotIn("Запустить проверку", self.template)
        self.assertNotIn("Запустите A → B → A", self.template)
        self.assertIn("Каждый выпуск проверяется автоматически", self.template)
        self.assertIn("профиль, proxy, встроенный Chromium", self.template)

    def test_landing_does_not_freeze_apple_silicon_generations(self) -> None:
        self.assertNotIn("M1–M4", self.template)
        self.assertIn("Apple Silicon (ARM64)", self.template)

    def test_affpapa_rollback_claim_is_channel_scoped(self) -> None:
        latest_items = self.content["changelog"][0]["items"]
        self.assertTrue(
            any("AffPapa автоматически откатывается" in item for item in latest_items)
        )


if __name__ == "__main__":
    unittest.main()
