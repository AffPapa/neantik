import json
import subprocess
import sys
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "preflight-runtime-rebase.py"
PLAN = PROJECT_ROOT / "runtime" / "chromium-152-rebase-plan.json"


class RuntimeRebaseEntrypointTests(unittest.TestCase):
    def test_version_neutral_entrypoint_uses_explicit_current_plan(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "/private/tmp/neantik-neutral-preflight-test",
                "--plan",
                str(PLAN),
                "--free-gib",
                "100",
                "--json",
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertFalse(report["ok"])
        self.assertIn("152.0.7977.64", report["error"])
        self.assertIn("153.0.8010.52", report["error"])


if __name__ == "__main__":
    unittest.main()
