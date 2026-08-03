from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseLauncherTests(unittest.TestCase):
    def test_launcher_builds_or_verifies_zip_and_dmg_without_app_store(self) -> None:
        text = (ROOT / "Release-NeAntik.command").read_text()

        self.assertIn("verify-direct-notarized-archive.py", text)
        self.assertIn("release-direct-dmg.sh", text)
        self.assertIn("verify-direct-notarized-dmg.sh", text)
        self.assertIn("Канал выпуска: Direct Distribution.", text)
        self.assertIn("ZIP уже существует", text)
        self.assertIn("DMG уже существует", text)
        self.assertNotIn("app-store", text.lower())
        self.assertNotIn("notarytool", text)


if __name__ == "__main__":
    unittest.main()
