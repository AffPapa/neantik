from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PackageAppScriptContractTests(unittest.TestCase):
    def test_build_output_is_canonicalized_before_secure_helper_packaging(self) -> None:
        text = (ROOT / "scripts/package-app.sh").read_text(encoding="utf-8")
        resolve = 'BIN_PATH="$(cd "$BIN_PATH" && pwd -P)"'
        helper = 'package-update-helpers.py" "$APP_DIR" "$BIN_PATH"'
        self.assertIn(resolve, text)
        self.assertLess(text.index(resolve), text.index(helper))

    def test_manager_update_output_is_canonicalized_before_secure_helper_packaging(self) -> None:
        text = (ROOT / "scripts/prepare-direct-manager-update.sh").read_text(encoding="utf-8")
        resolve = 'BIN_PATH="$(cd "$BIN_PATH" && pwd -P)"'
        helper = 'package-update-helpers.py" "$CANDIDATE_APP" "$BIN_PATH"'
        self.assertIn(resolve, text)
        self.assertLess(text.index(resolve), text.index(helper))

    def test_manager_update_records_chromium_only_scope_before_signing(self) -> None:
        text = (ROOT / "scripts/prepare-direct-manager-update.sh").read_text(encoding="utf-8")
        self.assertIn('NEANTIK_CHROMIUM_ONLY must be 0 or 1', text)
        marker = "Add :NeAntikEngineScope string chromium-only"
        self.assertIn(marker, text)
        self.assertLess(text.index('cp "$PROJECT_DIR/Resources/Info.plist"'), text.index(marker))
        self.assertLess(text.index(marker), text.index('package-update-helpers.py" "$CANDIDATE_APP"'))
        conflict = 'Chromium-only manager cannot include the owned WebKit host.'
        self.assertIn(conflict, text)
        self.assertLess(text.index(conflict), text.index('swift build \\'))

    def test_local_adhoc_candidate_disables_update_channel_before_helper_packaging(self) -> None:
        text = (ROOT / 'scripts/prepare-direct-manager-update.sh').read_text(encoding='utf-8')
        local = text.index('if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then', text.index('cp "$PROJECT_DIR/Resources/Info.plist"'))
        disable = text.index("Set :NeAntikUpdateChannelEnabled false", local)
        helpers = text.index('package-update-helpers.py" "$CANDIDATE_APP" "$BIN_PATH" -', local)
        production = text.index('package-update-helpers.py" "$CANDIDATE_APP" "$BIN_PATH" "$NEANTIK_SIGNING_IDENTITY"', helpers)
        self.assertLess(disable, helpers)
        self.assertLess(helpers, production)

    def test_local_adhoc_candidate_exits_before_public_release_gate(self) -> None:
        text = (ROOT / 'scripts/prepare-direct-manager-update.sh').read_text(encoding='utf-8')
        local = text.index('if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then', text.index('verify-public-artifact-privacy.py'))
        public_gate = text.index('verify-integrated-release.sh', local)
        early_exit = text.index('exit 0', local)
        self.assertLess(early_exit, public_gate)
        self.assertIn('release-channel and integrated-publication gates are intentionally not claimed', text[local:early_exit])

    @unittest.skipUnless(Path('/usr/libexec/PlistBuddy').is_file(), 'macOS PlistBuddy required')
    def test_manager_update_scope_marker_applies_only_to_chromium_builds(self) -> None:
        text = (ROOT / 'scripts/prepare-direct-manager-update.sh').read_text(encoding='utf-8')
        start = text.index('if [[ "${NEANTIK_CHROMIUM_ONLY:-0}" == "1" ]]; then', text.index('cp "$PROJECT_DIR/Resources/Info.plist"'))
        end = text.index('\nfi', start) + len('\nfi')
        with tempfile.TemporaryDirectory(prefix='neantik-scope-marker-') as temporary:
            app = Path(temporary) / 'Owned.app'
            (app / 'Contents').mkdir(parents=True)
            info = app / 'Contents/Info.plist'
            for enabled in ('0', '1'):
                with self.subTest(enabled=enabled):
                    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'synthetic'}))
                    env = os.environ.copy(); env.update(CANDIDATE_APP=str(app), NEANTIK_CHROMIUM_ONLY=enabled)
                    subprocess.run(['/bin/zsh', '-c', text[start:end]], env=env, check=True, capture_output=True)
                    self.assertEqual(plistlib.loads(info.read_bytes()).get('NeAntikEngineScope'), 'chromium-only' if enabled == '1' else None)

    def test_manager_update_refuses_conflicting_engine_selection(self) -> None:
        text = (ROOT / 'scripts/prepare-direct-manager-update.sh').read_text(encoding='utf-8')
        start = text.index('if [[ "${NEANTIK_CHROMIUM_ONLY:-0}" == "1" && "$WEBKIT_HOST_ENABLED" == "1" ]]')
        end = text.index('\nfi', start) + len('\nfi')
        for chromium, webkit, expected in [('1', '1', 78), ('1', '0', 0), ('0', '1', 0)]:
            with self.subTest(chromium=chromium, webkit=webkit):
                env = os.environ.copy(); env.update(NEANTIK_CHROMIUM_ONLY=chromium, WEBKIT_HOST_ENABLED=webkit)
                result = subprocess.run(['/bin/zsh', '-c', text[start:end]], env=env, capture_output=True)
                self.assertEqual(result.returncode, expected)

    def test_unqualified_runtime_gate_is_scoped_to_bundle_only_preparation(self) -> None:
        text = (ROOT / "scripts/prepare-direct-manager-update.sh").read_text(encoding="utf-8")
        gate = 'if [[ "$PREPARATION_MODE" == "bundle-only" ]]; then\n      SECURITY_BASELINE_ARGS+=(--allow-unqualified-bundle)'
        self.assertIn(gate, text)

    def test_manager_update_refreshes_sealed_site_protection_from_same_source(self) -> None:
        text = (ROOT / "scripts/prepare-direct-manager-update.sh").read_text(encoding="utf-8")
        clone = text.index('ditto --norsrc "$SOURCE_APP" "$CANDIDATE_APP"')
        refresh = text.index('"$PROJECT_DIR/Resources/SiteProtection"', clone)
        manager = text.index('cp "$MANAGER_BINARY" "$CANDIDATE_APP/Contents/MacOS/NeAntik"', clone)
        signing = text.index('rm -rf "$CANDIDATE_APP/Contents/_CodeSignature"', clone)
        self.assertLess(clone, refresh)
        self.assertLess(refresh, manager)
        self.assertLess(manager, signing)
        self.assertIn('rm -rf "$CANDIDATE_APP/Contents/Resources/SiteProtection"', text[clone:refresh])

    def test_local_dev_refreshes_sealed_site_protection_in_disposable_copy(self) -> None:
        text = (ROOT / "scripts/run-local-manager.sh").read_text(encoding="utf-8")
        refresh = text.index('"$PROJECT_DIR/Resources/SiteProtection"')
        verify = text.index('verify_site_protection_package.py', refresh)
        copy_binary = text.index('/bin/cp "$MANAGER_BINARY"', refresh)
        self.assertIn('"$DEVELOPMENT_APP/Contents/Resources/SiteProtection"', text[refresh:copy_binary])
        self.assertLess(verify, copy_binary)

    def test_manager_update_verifies_sealed_site_protection_before_signing(self) -> None:
        text = (ROOT / "scripts/prepare-direct-manager-update.sh").read_text(encoding="utf-8")
        verify = text.index('verify_site_protection_package.py')
        sign = text.index('direct_backup_signing.py" sign "$CANDIDATE_APP"')
        self.assertLess(verify, sign)

    def test_chromium_only_build_omits_owned_webkit_host_product(self) -> None:
        text = (ROOT / "scripts/package-app.sh").read_text(encoding="utf-8")
        self.assertIn('NEANTIK_CHROMIUM_ONLY must be 0 or 1', text)
        self.assertIn('NEANTIK_CHROMIUM_ONLY=1 swift build "${SWIFT_BUILD_ARGS[@]}" --product NeAntik', text)
        self.assertIn('--product NeAntikUpdateAssessment', text)
        self.assertIn('--product NeAntikUpdateOwner', text)
        self.assertIn('NEANTIK_CHROMIUM_ONLY="${NEANTIK_CHROMIUM_ONLY:-0}" swift build', text)
        self.assertNotIn('--product NeAntikWebKitHost', text)
        self.assertIn("Add :NeAntikEngineScope string chromium-only", text)

    def test_integrated_packager_enables_chromium_only_manager_gate(self) -> None:
        text = (ROOT / "scripts/package-integrated-app.sh").read_text(encoding="utf-8")
        self.assertIn('NEANTIK_CHROMIUM_ONLY=1 \\', text)
        self.assertIn('156.0.8078.80', text)


if __name__ == "__main__":
    unittest.main()
