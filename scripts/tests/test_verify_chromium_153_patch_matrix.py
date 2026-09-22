from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / (
    "verify-chromium-153-patch-matrix.py"
)
SPEC = importlib.util.spec_from_file_location("chromium_153_patch_matrix", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Chromium153PatchMatrixTests(unittest.TestCase):
    def test_missing_source_root_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "missing"
            with self.assertRaisesRegex(MODULE.MatrixError, "source root"):
                MODULE.verify(missing)


if __name__ == "__main__":
    unittest.main()
