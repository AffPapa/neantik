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
        self.assertIn(
            'verify-direct-version-bump.py" --floor-only',
            text,
        )
        normal_call = text.rindex('--project-root')
        self.assertLess(text.index('verify-direct-version-bump.py" --floor-only'), normal_call)
        self.assertIn('ditto -x -k "$ZIP_PATH" "$ARCHIVE_ROOT"', text)
        self.assertIn('APP_PATH="$ARCHIVE_ROOT/NeAntik.app"', text)
        self.assertIn('RUNTIME_APP="$APP_PATH/Contents/Resources/NeAntik Browser.app"', text)
        self.assertIn("APP_SIZE_KB >= 100000", text)
        self.assertIn("DMG_SIZE >= 50000000", text)
        self.assertLess(text.index("DMG_SIZE >= 50000000"), normal_call)
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
            normal_call,
        )
        self.assertIn("Applications shortcut", text)
        verification_text = (
            ROOT / "scripts" / "verify-direct-notarized-dmg.sh"
        ).read_text()
        self.assertIn(
            'python3 "$PROJECT_DIR/scripts/verify-public-artifact-privacy.py" "$APP_PATH"',
            verification_text,
        )

    def test_release_script_requires_accepted_and_all_outer_gates(self) -> None:
        text = (ROOT / "scripts" / "release-direct-dmg.sh").read_text()
        self.assertIn('notarize_dmg_transaction.py', text)
        self.assertIn('--dmg "$TEMP_DMG" --zip "$ZIP_PATH"', text)
        self.assertIn('python3 -I -B', text)
        self.assertNotIn('notarytool submit', text)
        driver = (ROOT / "scripts/notarize_dmg_transaction.py").read_text()
        self.assertIn('notary.parse_notary_result(output, expected_identifier=identifier)', driver)
        self.assertIn('"stapler", "staple"', driver)
        self.assertIn('verify-direct-notarized-dmg.sh', driver)
        self.assertIn('publish_or_adopt_sealed_file', driver)
        self.assertNotIn('--wait', driver)
        preflight = driver[driver.index('if args.check_new:'):driver.index('if args.resume:', driver.index('if args.check_new:'))]
        self.assertIn('source.capture_release_source(project, closure=POLICY_CLOSURE)', preflight)
        self.assertNotIn('start(', preflight.split('# Catch')[0])
        self.assertNotIn('notarytool', preflight)
        self.assertLess(driver.index('verify-direct-notarized-dmg.sh'), driver.index('publish_or_adopt_sealed_file'))

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
