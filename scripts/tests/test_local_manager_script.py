import pathlib
import plistlib
import shlex
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-local-manager.sh"
WRAPPER = ROOT / "Develop-NeAntik.command"
OPEN_SOURCE_VERIFIER = ROOT / "scripts" / "verify-open-source-tree.py"


class LocalManagerScriptTests(unittest.TestCase):
    def test_fast_path_is_isolated_from_release(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("app.neantik.desktop.dev", text)
        self.assertIn("NeAntik Development", text)
        self.assertIn("app.neantik.dev.proxy", text)
        self.assertIn('SOURCE_APP="${NEANTIK_DEV_SOURCE_APP:-$PROJECT_DIR/dist/NeAntik.app}"', text)
        self.assertIn('if [[ -L "$SOURCE_APP" || ! -d "$SOURCE_APP"', text)
        self.assertIn("NEANTIK_DEV_SOURCE_APP=/path/NeAntik.app", text)
        self.assertIn('if [[ -n "${NEANTIK_DEV_APP_PATH:-}" ]]; then', text)
        self.assertIn("/private/tmp/neantik-[A-Za-z0-9_-]+/NeAntik-Dev\\.app", text)
        self.assertIn("%Lp", text)
        self.assertIn('-e "$DEVELOPMENT_APP" || -L "$DEVELOPMENT_APP"', text)
        self.assertIn("NEANTIK_DEV_APP_PATH=/private/tmp/neantik-*/NeAntik-Dev.app", text)
        self.assertIn('source "$PROJECT_DIR/scripts/resolve-webkit-proxy-build-mode.sh"', text)
        self.assertIn("disabled|qualification", text)
        self.assertIn("local Dev builder permits only disabled or private QA qualification mode", text)
        self.assertIn("--scratch-path", text)
        self.assertIn("--disable-sandbox", text)
        self.assertIn("/bin/cp -cR", text)
        self.assertIn(
            'DEVELOPMENT_RUNTIME_APP="$DEVELOPMENT_APP/Contents/Resources/NeAntik Browser.app"',
            text,
        )
        self.assertIn('"$DEVELOPMENT_RUNTIME_APP"', text)
        self.assertIn("--deep", text)
        self.assertIn("--strict", text)
        self.assertIn("--sign -", text)
        self.assertIn('--deep \\\n  --sign - \\\n  "$DEVELOPMENT_APP"', text)
        self.assertIn(
            'DEVELOPMENT_INFO_STRINGS="$DEVELOPMENT_APP/Contents/Resources/ru.lproj/InfoPlist.strings"',
            text,
        )
        self.assertGreaterEqual(
            text.count("Set :CFBundleDisplayName NeAntik Dev"),
            2,
        )
        self.assertIn('cd "$PROJECT_DIR"', text)
        self.assertIn(
            'exec /usr/bin/open -n "$DEVELOPMENT_APP"',
            text,
        )
        self.assertNotIn('exec "$DEVELOPMENT_APP/Contents/MacOS/NeAntik"', text)
        self.assertIn("NeAntikDevelopmentFixtureRoot", text)
        self.assertIn("production source/notice coverage and native runtime qualification", text)
        self.assertIn("docs/NEXT_1_0_SLICES.md", text)

        for forbidden in (
            "notarytool",
            "stapler",
            "Release-NeAntik.command",
            "direct-candidate-manifest",
            "fingerprint-audit",
            "neantik-affpapa-release",
            "github",
        ):
            self.assertNotIn(forbidden, text)

    @unittest.skipUnless(pathlib.Path("/usr/libexec/PlistBuddy").is_file(), "macOS plist control")
    def test_fixture_feature_key_handles_cached_bundles(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        start = text.index("if (( USE_FRESH_FIXTURE == 1 )); then")
        end = text.index("  DEVELOPMENT_FIXTURE_ROOT=", start)
        operations = text[start:end].split("then", 1)[1]
        for initial in ({}, {"NeAntikWebKitMediaPolicyEnabled": False},
                        {"NeAntikWebKitMediaPolicyEnabled": "obsolete"}):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as root:
                info = pathlib.Path(root) / "Info.plist"
                info.write_bytes(plistlib.dumps({"UnrelatedMarker": "preserved", **initial}))
                subprocess.run(["/bin/zsh", "-c", "set -e; INFO_PLIST=" +
                    shlex.quote(str(info)) + "\n" + operations], check=True, capture_output=True)
                actual = plistlib.loads(info.read_bytes())
                self.assertIs(actual["NeAntikWebKitMediaPolicyEnabled"], True)
                self.assertEqual(actual["UnrelatedMarker"], "preserved")

    @unittest.skipUnless(pathlib.Path("/usr/libexec/PlistBuddy").is_file(), "macOS plist control")
    def test_dev_bundle_disables_production_backup_capability(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        marker = "# A copied release bundle may carry the production-only BrowserData backup"
        start = text.index(marker)
        next_command = text.index('  -c "Set :CFBundleDisplayName NeAntik Dev"', start)
        end = text.rfind("/usr/libexec/PlistBuddy", start, next_command)
        operations = text[start:end].split("\n", 1)[1]

        for initial in ({}, {"NeAntikBrowserDataBackupEnabled": True},
                        {"NeAntikBrowserDataBackupEnabled": False}):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as root:
                info = pathlib.Path(root) / "Info.plist"
                info.write_bytes(plistlib.dumps({"UnrelatedMarker": "preserved", **initial}))
                subprocess.run(["/bin/zsh", "-c", "set -e; INFO_PLIST=" +
                    shlex.quote(str(info)) + "\n" + operations], check=True, capture_output=True)
                actual = plistlib.loads(info.read_bytes())
                self.assertIs(actual["NeAntikBrowserDataBackupEnabled"], False)
                self.assertEqual(actual["UnrelatedMarker"], "preserved")

    def test_fast_path_never_rewrites_dist(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('>"$SOURCE_APP', text)
        self.assertNotIn('codesign --force --deep --sign - "$SOURCE_APP', text)
        self.assertNotIn("dist/NeAntik-Integrated.app", text)
        self.assertIn(
            'DEVELOPMENT_ROOT="$PROJECT_DIR/.build/neantik-local"',
            text,
        )
        self.assertIn(
            'DEVELOPMENT_APP="$DEVELOPMENT_ROOT/NeAntik-Dev.app"',
            text,
        )

    def test_root_wrapper_only_dispatches_to_local_manager(self) -> None:
        text = WRAPPER.read_text(encoding="utf-8")
        self.assertIn("scripts/run-local-manager.sh", text)
        self.assertNotIn("Release-NeAntik", text)

    def test_open_source_gate_ignores_only_gitignored_build_outputs(
        self,
    ) -> None:
        text = OPEN_SOURCE_VERIFIER.read_text(encoding="utf-8")
        self.assertIn('"--cached"', text)
        self.assertIn('"--others"', text)
        self.assertIn('"--exclude-standard"', text)
        self.assertIn(
            "Exported source archives may not contain .git",
            text,
        )


if __name__ == "__main__":
    unittest.main()
