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


if __name__ == "__main__":
    unittest.main()
