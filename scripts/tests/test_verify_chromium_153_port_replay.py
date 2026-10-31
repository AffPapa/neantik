from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / (
    "verify-chromium-153-port-replay.py"
)
SPEC = importlib.util.spec_from_file_location("chromium_153_port_replay", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Chromium153PortReplayTests(unittest.TestCase):
    def test_path_free_output_removes_build_paths(self) -> None:
        result = MODULE.path_free(
            {
                "sourceRoot": "/private/tmp/source",
                "nested": {"candidateAppPath": "/private/tmp/app"},
                "status": "source-replay-verified",
            }
        )

        self.assertNotIn("sourceRoot", result)
        self.assertNotIn("candidateAppPath", result["nested"])
        self.assertEqual(result["status"], "source-replay-verified")

    def test_path_free_rejects_unexpected_absolute_path(self) -> None:
        with self.assertRaisesRegex(MODULE.ReplayError, "local path"):
            MODULE.path_free({"unexpected": "/private/tmp/not-allowed"})


if __name__ == "__main__":
    unittest.main()
