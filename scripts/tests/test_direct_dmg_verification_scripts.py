from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DirectDMGVerificationScriptTests(unittest.TestCase):
    def test_owned_temporary_alias_is_canonicalized_before_paths_are_derived(self) -> None:
        for filename in ("release-direct-dmg.sh", "verify-direct-notarized-dmg.sh"):
            text = (ROOT / "scripts" / filename).read_text()
            canonical = 'TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"'
            self.assertLess(text.index(canonical), text.index('MOUNT_POINT="$TEMP_ROOT/mount"'))
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                owned = root / "owned"
                owned.mkdir()
                alias = root / "alias"
                alias.symlink_to(owned, target_is_directory=True)
                result = subprocess.run(
                    ["/bin/zsh", "-c", canonical + '\nprint -r -- "$TEMP_ROOT"'],
                    env={"TEMP_ROOT": str(alias)}, capture_output=True, text=True, check=True,
                )
                self.assertEqual(result.stdout.strip(), str(owned))
                # Canonicalizing our root does not authorize an external symlink input.
                import sys
                sys.path.insert(0, str(ROOT / "scripts"))
                import direct_provisioning_contract as contract
                payload = owned / "profile"
                payload.write_bytes(b"synthetic")
                with self.assertRaisesRegex(contract.ContractError, "non-symlink"):
                    contract.read_regular(alias / "profile")
                self.assertEqual(contract.read_regular(payload), b"synthetic")

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

    def test_release_runs_independent_verifier_before_exclusive_publication(self) -> None:
        text = (ROOT / "scripts" / "release-direct-dmg.sh").read_text()
        self.assertIn('notarize_dmg_transaction.py', text)
        driver = (ROOT / "scripts/notarize_dmg_transaction.py").read_text()
        self.assertLess(driver.index('verify-direct-notarized-dmg.sh'), driver.index('publish_or_adopt_sealed_file'))
        self.assertIn('"sidecar-committed"', driver)
        self.assertNotIn('mv "$TEMP_DMG"', text)

    def test_hosted_wrapper_is_read_only_and_version_driven(self) -> None:
        wrapper = (
            ROOT
            / "scripts"
            / "Run-NeAntik-DMG-Hosted-Verification.command"
        )
        text = wrapper.read_text()
        self.assertTrue(wrapper.stat().st_mode & stat.S_IXUSR)
        self.assertIn("verify-direct-hosted-dmg.sh", text)
        self.assertIn(
            "https://affpapa.org/neantik/downloads/"
            "NeAntik-$VERSION-arm64-notarized.dmg",
            text,
        )
        self.assertIn("GitHub Release и сайт не изменялись", text)
        self.assertNotIn("gh release upload", text)
        self.assertNotIn("notarytool submit", text)


if __name__ == "__main__":
    unittest.main()
