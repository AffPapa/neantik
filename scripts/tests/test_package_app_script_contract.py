from pathlib import Path
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
