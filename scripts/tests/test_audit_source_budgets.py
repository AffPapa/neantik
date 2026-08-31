from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "audit-source-budgets.py"
SPEC = importlib.util.spec_from_file_location("audit_source_budgets", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SourceBudgetTests(unittest.TestCase):
    def test_small_source_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Small.swift").write_text("struct Small {}\n", encoding="utf-8")
            report = MODULE.inspect(root)
            self.assertEqual(report["verdict"], "pass")

    def test_oversized_source_fails_both_budgets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = ("let value = 1\n" * (MODULE.DEFAULT_MAX_LINES + 1)) + (
                "x" * MODULE.DEFAULT_MAX_BYTES
            )
            (root / "Large.swift").write_text(payload, encoding="utf-8")
            report = MODULE.inspect(root)
            self.assertEqual(report["verdict"], "fail")
            self.assertEqual(len(report["failures"]), 2)


if __name__ == "__main__":
    unittest.main()
