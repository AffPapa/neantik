from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DirectDMGReleaseScriptTests(unittest.TestCase):
    def test_release_script_fails_closed_before_notarization(self) -> None:
        text = (ROOT / "scripts" / "release-direct-dmg.sh").read_text()
        self.assertIn(
            'PREPARED_APP_PATH="$PROJECT_DIR/dist/NeAntik.app"',
            text,
        )
        self.assertIn(
            'ZIP_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.zip"',
            text,
        )
        self.assertIn(
            'verify-direct-notarized-archive.py',
            text,
        )
        self.assertIn('ditto -x -k "$ZIP_PATH" "$ARCHIVE_ROOT"', text)
        self.assertIn('APP_PATH="$ARCHIVE_ROOT/NeAntik.app"', text)
        self.assertIn('RUNTIME_APP="$APP_PATH/Contents/Resources/NeAntik Browser.app"', text)
        self.assertIn("APP_SIZE_KB >= 100000", text)
        self.assertIn("DMG_SIZE >= 50000000", text)
        self.assertLess(text.index("DMG_SIZE >= 50000000"), text.index("notarytool submit"))
        self.assertIn("codesign --verify --deep --strict", text)
        self.assertIn("Developer ID Application:", text)
        self.assertIn("--extract-certificates=", text)
        self.assertIn('shasum -a 1 "$LEAF_CERTIFICATE"', text)
        self.assertIn("toupper($1)", text)
        self.assertIn("^[0-9A-F]{40}$", text)
        self.assertNotIn('SIGNING_IDENTITY="$DEFAULT_IDENTITY"', text)
        self.assertNotIn("NEANTIK_SIGNING_IDENTITY", text)
        self.assertIn("DMG has no usable Developer ID Application signature", text)
        self.assertLess(
            text.index("DMG has no usable Developer ID Application signature"),
            text.index("notarytool submit"),
        )
        self.assertIn("Applications shortcut", text)
        self.assertIn("NEANTIK_NOTARY_KEYCHAIN", text)
        self.assertIn('"${NOTARY_KEYCHAIN_ARGUMENTS[@]}"', text)
        self.assertIn("explicit notary Keychain must be owner-only", text)

    def test_release_script_requires_accepted_and_all_outer_gates(self) -> None:
        text = (ROOT / "scripts" / "release-direct-dmg.sh").read_text()
        self.assertIn("--output-format json", text)
        self.assertIn("payload.get(\"id\")", text)
        self.assertIn("payload.get(\"status\")", text)
        self.assertIn("notarytool log", text)
        self.assertNotIn("awk '/^[[:space:]]*status:", text)
        self.assertIn('[[ "$NOTARY_STATUS" == "Accepted" ]]', text)
        self.assertIn("xcrun stapler staple", text)
        self.assertIn("xcrun stapler validate", text)
        self.assertIn("--context context:primary-signature", text)
        self.assertIn("shasum -a 256", text)
        self.assertIn("stapled DMG lost its Developer ID Application signature", text)
        self.assertLess(text.index("spctl \\\n  --assess"), text.index('mv "$TEMP_DMG" "$DMG_PATH"'))

    def test_wrapper_has_no_placeholder_identity_or_secret_prompt(self) -> None:
        text = (
            ROOT / "scripts" / "Run-NeAntik-DMG-Release.command"
        ).read_text()
        self.assertIn('echo "NeAntik $VERSION', text)
        self.assertIn("release-direct-dmg.sh", text)
        self.assertIn("neantik-notary", text)
        self.assertNotIn("Developer ID Application: …", text)
        self.assertNotIn("app-specific", text.lower())


if __name__ == "__main__":
    unittest.main()
