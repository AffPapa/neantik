from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DirectDMGReleaseScriptTests(unittest.TestCase):
    def test_release_script_fails_closed_before_notarization(self) -> None:
        text = (ROOT / "scripts" / "release-direct-dmg.sh").read_text()
        self.assertIn('APP_PATH="$PROJECT_DIR/dist/NeAntik.app"', text)
        self.assertIn('RUNTIME_APP="$APP_PATH/Contents/Resources/NeAntik Browser.app"', text)
        self.assertIn("APP_SIZE_KB >= 100000", text)
        self.assertIn("DMG_SIZE >= 50000000", text)
        self.assertLess(text.index("DMG_SIZE >= 50000000"), text.index("notarytool submit"))
        self.assertIn("codesign --verify --deep --strict", text)
        self.assertIn("Developer ID Application:", text)
        self.assertIn("could not derive the Developer ID Application identity", text)
        self.assertIn('SIGNING_IDENTITY="$DEFAULT_IDENTITY"', text)
        self.assertNotIn("NEANTIK_SIGNING_IDENTITY", text)
        self.assertIn("DMG has no usable Developer ID Application signature", text)
        self.assertLess(
            text.index("DMG has no usable Developer ID Application signature"),
            text.index("notarytool submit"),
        )
        self.assertIn("Applications shortcut", text)

    def test_release_script_requires_accepted_and_all_outer_gates(self) -> None:
        text = (ROOT / "scripts" / "release-direct-dmg.sh").read_text()
        self.assertIn('[[ "$NOTARY_STATUS" == "Accepted" ]]', text)
        self.assertIn("xcrun stapler staple", text)
        self.assertIn("xcrun stapler validate", text)
        self.assertIn("--context context:primary-signature", text)
        self.assertIn("shasum -a 256", text)
        self.assertIn("stapled DMG lost its Developer ID Application signature", text)
        self.assertLess(text.index("spctl \\\n  --assess"), text.index('mv "$TEMP_DMG" "$DMG_PATH"'))

    def test_wrapper_has_no_placeholder_identity_or_secret_prompt(self) -> None:
        text = (
            ROOT / "scripts" / "Run-NeAntik-0.3.12-DMG-Release.command"
        ).read_text()
        self.assertIn("release-direct-dmg.sh", text)
        self.assertIn("neantik-notary", text)
        self.assertNotIn("Developer ID Application: …", text)
        self.assertNotIn("app-specific", text.lower())


if __name__ == "__main__":
    unittest.main()
