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

    def test_unqualified_runtime_gate_is_scoped_to_bundle_only_preparation(self) -> None:
        text = (ROOT / "scripts/prepare-direct-manager-update.sh").read_text(encoding="utf-8")
        gate = 'if [[ "$PREPARATION_MODE" == "bundle-only" ]]; then\n      SECURITY_BASELINE_ARGS+=(--allow-unqualified-bundle)'
        self.assertIn(gate, text)

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
