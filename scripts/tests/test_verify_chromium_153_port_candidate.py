from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / (
    "verify-chromium-153-port-candidate.py"
)
SPEC = importlib.util.spec_from_file_location("chromium_153_port_candidate", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Chromium153PortCandidateTests(unittest.TestCase):
    def test_path_free_binding_keeps_only_candidate_evidence(self) -> None:
        binding = MODULE.path_free_binding(
            {
                "status": "bound-to-built-candidate",
                "candidateAppPath": "/private/tmp/secret.app",
                "candidateExecutableSHA256": "a" * 64,
                "candidateExecutableSize": 10,
                "candidateVersionOutput": "NeAntik Browser 153.0.8010.52",
                "sourceVersion": "153.0.8010.52",
                "architecture": "arm64",
                "angleEnableMetal": True,
                "argsGNPath": "/private/tmp/args.gn",
                "argsGNSHA256": "b" * 64,
                "policy": "candidate only",
            }
        )

        self.assertNotIn("candidateAppPath", binding)
        self.assertNotIn("argsGNPath", binding)
        self.assertEqual(binding["architecture"], "arm64")
        self.assertTrue(binding["angleEnableMetal"])


if __name__ == "__main__":
    unittest.main()
