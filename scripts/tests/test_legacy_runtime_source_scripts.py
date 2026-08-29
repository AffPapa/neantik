import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class RuntimeSourceScriptTests(unittest.TestCase):
    def test_prepare_uses_current_owned_source_pair(self) -> None:
        script = (
            PROJECT_ROOT / "scripts" / "prepare-runtime-source.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("chromium-152-rebase-plan.json", script)
        self.assertIn("verify-runtime-source-pair.py", script)

    def test_legacy_verifier_redirects_to_source_provenance(self) -> None:
        script = (
            PROJECT_ROOT / "scripts" / "verify-runtime-source.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("Legacy source-lock verification is blocked", script)
        self.assertIn("export-runtime-source-provenance.py", script)
        self.assertIn("verify-runtime-source-provenance.py", script)
        self.assertIn('if [[ -f "$SOURCE_CONTRACT" ]]', script)


if __name__ == "__main__":
    unittest.main()
