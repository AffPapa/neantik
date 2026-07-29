import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "build-runtime.sh"


class BuildRuntimeScriptTests(unittest.TestCase):
    def test_verifies_unpacked_chromium_source_version(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("verify_source_version()", script)
        self.assertIn('"$SOURCE_DIR/chrome/VERSION"', script)
        self.assertIn('"$actual_version" != "$EXPECTED_CHROMIUM_VERSION"', script)
        self.assertIn("Chromium source version mismatch.", script)

    def test_source_version_gate_runs_for_fresh_and_resumed_source(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        resumed_block = script.split('if [[ -f "$SOURCE_STAMP" ]]', 1)[1].split("return", 1)[0]
        fresh_block = script.split('"$BUILD_ROOT/ungoogled-chromium/utils/domain_substitution.py"', 1)[1].split(
            'printf \'%s\\n\'',
            1,
        )[0]

        self.assertIn("verify_source_version", resumed_block)
        self.assertIn("verify_source_version", fresh_block)


if __name__ == "__main__":
    unittest.main()
