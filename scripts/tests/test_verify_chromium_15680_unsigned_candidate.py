import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "verify-chromium-15680-unsigned-candidate.py"
BUILD_EVIDENCE_SCRIPT = PROJECT_ROOT / "scripts" / "complete-chromium-15680-build-evidence.py"


class Chromium15680UnsignedCandidateTests(unittest.TestCase):
    def test_postbuild_producer_rejects_nonzero_exit_without_mutating_pending_record(self) -> None:
        evidence = PROJECT_ROOT / "runtime/chromium-15680-build-evidence.json"
        before = hashlib.sha256(evidence.read_bytes()).hexdigest()
        result = subprocess.run(
            [sys.executable, "-B", str(BUILD_EVIDENCE_SCRIPT),
             "/private/tmp/neantik-chromium-15680-stage/src",
             "--project-root", str(PROJECT_ROOT), "--ninja-log", "/no/ninja.log",
             "--ninja-exit-code", "1"],
            cwd=PROJECT_ROOT,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ninja did not exit successfully", result.stderr)
        self.assertEqual(hashlib.sha256(evidence.read_bytes()).hexdigest(), before)

    def test_pending_build_evidence_fails_closed_before_signing(self) -> None:
        evidence = PROJECT_ROOT / "runtime/chromium-15680-build-evidence.json"
        before = hashlib.sha256(evidence.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            adoption = json.loads((PROJECT_ROOT / "runtime/chromium-15680-source-adoption-v1.json").read_text())
            adoption["buildEvidenceSHA256"] = None
            pending = Path(temporary) / "pending-adoption.json"
            pending.write_text(json.dumps(adoption), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "-B", str(SCRIPT), "/no/app", "/no/args.gn", str(pending)],
                cwd=PROJECT_ROOT,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build evidence is not bound by adoption manifest", result.stderr)
        self.assertEqual(hashlib.sha256(evidence.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
