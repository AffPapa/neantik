#!/usr/bin/env python3
"""Run the full local Python contract suite after its OS capability preflight."""
import json
import os
from pathlib import Path
import subprocess
import sys

from execution_capabilities import full_run_capability_gaps

ROOT = Path(__file__).resolve().parent.parent


def main():
    gaps = full_run_capability_gaps()
    if gaps:
        print(json.dumps({
            "schemaVersion": 1,
            "status": "blocked",
            "reason": "required-execution-capabilities-unavailable",
            "missingCapabilities": gaps,
            "testsStarted": False,
            "releaseGate": False,
        }))
        return 75

    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    result = subprocess.run(
        [sys.executable, "-B", "-m", "unittest", "discover", "-s", "scripts/tests", "-p", "test_*.py"],
        cwd=ROOT, env=env, check=False,
    )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
