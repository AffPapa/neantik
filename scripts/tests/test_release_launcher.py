from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseLauncherTests(unittest.TestCase):
    def test_launcher_always_builds_exact_zip_and_dmg_without_app_store(self) -> None:
        text = (ROOT / "Release-NeAntik.command").read_text()

        self.assertIn('"$RELEASE_SCRIPT"', text)
        self.assertIn("release-direct-dmg.sh", text)
        self.assertIn("Канал выпуска: Direct Distribution.", text)
        self.assertNotIn("ZIP уже существует", text)
        self.assertNotIn("DMG уже существует", text)
        self.assertNotIn('if [[ -f "$ZIP_PATH" ]]', text)
        self.assertNotIn('if [[ -f "$DMG_PATH" ]]', text)
        self.assertIn("previous_artifacts=", text)
        self.assertIn("private-release-attempts", text)
        self.assertIn('mv "$artifact" "$previous_dir/"', text)
        self.assertNotIn("app-store", text.lower())
        self.assertNotIn("notarytool", text)


if __name__ == "__main__":
    unittest.main()
