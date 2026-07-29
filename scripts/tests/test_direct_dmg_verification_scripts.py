from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DirectDMGVerificationScriptTests(unittest.TestCase):
    def test_local_verifier_covers_container_and_mounted_app(self) -> None:
        text = (ROOT / "scripts" / "verify-direct-notarized-dmg.sh").read_text()
        self.assertIn("DMG_SIZE >= 50000000", text)
        self.assertIn('[[ "$RECORDED_NAME" == "$EXPECTED_NAME" ]]', text)
        self.assertIn('hdiutil verify "$DMG_PATH"', text)
        self.assertIn("codesign --verify --verbose=2", text)
        self.assertIn("^Authority=Developer ID Application:", text)
        self.assertIn("^Timestamp=", text)
        self.assertIn('xcrun stapler validate "$DMG_PATH"', text)
        self.assertIn("--context context:primary-signature", text)
        self.assertIn("NeAntik Browser.app", text)
        self.assertIn("Applications shortcut", text)
        self.assertIn("verify-integrated-release.sh", text)
        self.assertIn('xcrun stapler validate "$APP_PATH"', text)
        self.assertIn('spctl --assess --type execute', text)

    def test_hosted_verifier_binds_download_to_local_final_image(self) -> None:
        text = (ROOT / "scripts" / "verify-direct-hosted-dmg.sh").read_text()
        self.assertIn('[[ "$DOWNLOAD_URL" == https://* ]]', text)
        self.assertIn('[[ "$DOWNLOAD_URL" != *"@"* ]]', text)
        self.assertIn('[[ "$DOWNLOAD_URL" != *"#"* ]]', text)
        self.assertIn("--proto '=https'", text)
        self.assertIn("--tlsv1.2", text)
        self.assertIn('[[ "$DOWNLOADED_SHA" == "$EXPECTED_SHA" ]]', text)
        self.assertIn('[[ "$DOWNLOADED_SIZE" == "$EXPECTED_SIZE" ]]', text)
        self.assertGreaterEqual(text.count("verify-direct-notarized-dmg.sh"), 2)

    def test_release_runs_independent_verifier_before_final_move(self) -> None:
        text = (ROOT / "scripts" / "release-direct-dmg.sh").read_text()
        verify_index = text.index('verify-direct-notarized-dmg.sh" "$TEMP_DMG"')
        move_index = text.index('mv "$TEMP_DMG" "$DMG_PATH"')
        self.assertLess(verify_index, move_index)
        self.assertIn('mv "$TEMP_DMG.sha256" "$CHECKSUM_PATH"', text)

    def test_hosted_wrapper_is_read_only_and_uses_canonical_github_asset(self) -> None:
        text = (
            ROOT
            / "scripts"
            / "Run-NeAntik-0.3.12-DMG-Hosted-Verification.command"
        ).read_text()
        self.assertIn("verify-direct-hosted-dmg.sh", text)
        self.assertIn(
            "https://github.com/AffPapa/neantik/releases/download/v0.3.12/"
            "NeAntik-0.3.12-arm64-notarized.dmg",
            text,
        )
        self.assertIn("GitHub Release и сайт не изменялись", text)
        self.assertNotIn("gh release upload", text)
        self.assertNotIn("notarytool submit", text)


if __name__ == "__main__":
    unittest.main()
