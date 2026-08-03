import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class LegacyRuntimeSourceScriptTests(unittest.TestCase):
    def test_legacy_prepare_is_fail_closed_for_chromium_150(self) -> None:
        script = (
            PROJECT_ROOT / "scripts" / "prepare-runtime-source.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("Legacy source-pair preparation is blocked", script)
        self.assertIn("chromium-150-source-contract.json", script)

    def test_legacy_verifier_redirects_to_source_provenance(self) -> None:
        script = (
            PROJECT_ROOT / "scripts" / "verify-runtime-source.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("Legacy source-lock verification is blocked", script)
        self.assertIn("export-runtime-source-provenance.py", script)
        self.assertIn("verify-runtime-source-provenance.py", script)


if __name__ == "__main__":
    unittest.main()
