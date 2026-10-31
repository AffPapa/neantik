from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / (
    "verify-chromium-153-runtime-candidate.py"
)
SPEC = importlib.util.spec_from_file_location("chromium_153_runtime_candidate", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Chromium153RuntimeCandidateTests(unittest.TestCase):
    def test_args_require_arm64_and_metal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            args = Path(temporary) / "args.gn"
            args.write_text(
                'target_cpu = "arm64"\nangle_enable_metal = true\n',
                encoding="utf-8",
            )
            MODULE.verify_args(args)

    def test_args_reject_non_metal_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            args = Path(temporary) / "args.gn"
            args.write_text(
                'target_cpu = "arm64"\nangle_enable_metal = false\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(MODULE.RuntimeCandidateError, "Metal"):
                MODULE.verify_args(args)


if __name__ == "__main__":
    unittest.main()
