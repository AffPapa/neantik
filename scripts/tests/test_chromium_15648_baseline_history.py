import shutil
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
import chromium_15648_release_evidence as EVIDENCE  # noqa: E402


class Chromium15648BaselineHistoryTests(unittest.TestCase):
    def test_source_contract_uses_archived_baseline_after_release_refresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            (runtime / "licenses").mkdir(parents=True)
            (runtime / "security-baselines").mkdir()
            for relative in (
                "chromium-15648-source-contract.json",
                "chromium-15648-rebase-plan.json",
                "chromium-15648-source-adoption-v3.json",
                "security-baseline.json",
            ):
                shutil.copyfile(PROJECT_ROOT / "runtime" / relative, runtime / relative)
            shutil.copyfile(
                PROJECT_ROOT / "runtime/licenses/Chromium-LICENSE",
                runtime / "licenses/Chromium-LICENSE",
            )
            original = "66446fb6a7cdd00e783c5596fcd82cfeb7b900d8be2931ad5b1e8db028a3f6c8"
            shutil.copyfile(
                PROJECT_ROOT / "runtime/security-baselines" / f"{original}.json",
                runtime / "security-baselines" / f"{original}.json",
            )
            self.assertNotEqual(
                EVIDENCE._sha(runtime / "security-baseline.json"), original
            )
            contract = EVIDENCE.verify_contract(root)
            self.assertEqual(contract["securityBaselineSHA256"], original)


if __name__ == "__main__":
    unittest.main()
