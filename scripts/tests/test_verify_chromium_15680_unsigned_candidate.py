import hashlib
import importlib.util
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
    def test_loose_new_framework_does_not_admit_stale_or_symlinked_signing_input(self):
        spec = importlib.util.spec_from_file_location("unsigned15680", SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary).resolve(); app = out / "NeAntik Browser.app"
            relative = Path("NeAntik Browser Framework.framework/Versions/156.0.8078.80/NeAntik Browser Framework")
            loose = out / relative; loose.parent.mkdir(parents=True); loose.write_bytes(b"new linked bytes")
            nested = app / "Contents/Frameworks" / relative; nested.parent.mkdir(parents=True); nested.write_bytes(b"old shipped bytes")
            expected = hashlib.sha256(loose.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, "stale code"):
                module.verify_embedded_framework(app, "156.0.8078.80", out, expected)
            nested.write_bytes(loose.read_bytes())
            module.verify_embedded_framework(app, "156.0.8078.80", out, expected)
            nested.unlink(); nested.symlink_to(loose)
            with self.assertRaisesRegex(ValueError, "symlink"):
                module.verify_embedded_framework(app, "156.0.8078.80", out, expected)

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
