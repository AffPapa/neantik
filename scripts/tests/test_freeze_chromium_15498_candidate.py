import importlib.util
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "freeze-chromium-15498-candidate.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("freeze_chromium_15498_candidate", SCRIPT)
assert SPEC and SPEC.loader
FREEZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FREEZE)


class FreezeCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "LICENSE").write_text("fixture license\n")
        self.args_gn = self.source / "out/Release/args.gn"
        self.args_gn.parent.mkdir(parents=True)
        self.args_gn.write_text("angle_enable_metal = true\n")
        self.app = self.root / "NeAntik Browser.app"
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": FREEZE.VERSION,
            "CFBundleExecutable": "NeAntik Browser",
        }))
        (contents / "MacOS/NeAntik Browser").write_bytes(b"unsigned executable")
        framework = contents / "Frameworks/NeAntik Browser Framework.framework/Versions" / FREEZE.VERSION
        framework.mkdir(parents=True)
        (framework / "NeAntik Browser Framework").write_bytes(b"unsigned framework")
        evidence = self.runtime / "chromium-15498-source-evidence"
        evidence.mkdir()
        for name in FREEZE.EVIDENCE_NAMES:
            (evidence / name).write_text("{}\n")
        for name in (
            "chromium-15498-toolchain-lock.json", "security-baseline.json",
            "apple-device-tuples.json", "chromium-15498-rebase-plan.json",
        ):
            (self.runtime / name).write_text("{}\n")
        (self.runtime / "fingerprint-chromium-154.lock.json").write_text(json.dumps({
            "fingerprintChromium": {},
            "macPackaging": {},
            "ownedManifests": {},
        }))
        self.snapshot = {
            "schemaVersion": 2,
            "recordType": "chromium-source-snapshot",
            "targetChromiumVersion": FREEZE.VERSION,
            "sourceFileCount": 1_100_000,
            "deletedPathCount": 10,
        }

    def invoke(self, *, fail_lock=False):
        with patch.object(FREEZE, "PROJECT", self.root), \
             patch.object(FREEZE, "RUNTIME", self.runtime), \
             patch.object(FREEZE, "build_snapshot", return_value=self.snapshot), \
             patch.object(FREEZE, "compact_snapshot", side_effect=lambda value: value), \
             patch.object(FREEZE, "verify_contract"), \
             patch.object(FREEZE, "verify_candidate_document"), \
             patch.object(FREEZE, "verify_unsigned_binary_binding"), \
             patch.object(FREEZE, "verify_candidate_lock", side_effect=ValueError("injected lock failure") if fail_lock else None), \
             patch.object(sys, "argv", [str(SCRIPT), str(self.source), str(self.args_gn), str(self.app)]):
            return FREEZE.main()

    def test_exact_unsigned_candidate_is_bound_to_frozen_documents(self):
        self.assertEqual(self.invoke(), 0)
        candidate = json.loads((self.runtime / "chromium-15498-port-candidate.json").read_text())
        self.assertEqual(candidate["targetChromiumVersion"], FREEZE.VERSION)
        self.assertEqual(candidate["binaryBinding"]["candidateExecutableSHA256"],
                         FREEZE.digest(self.app / "Contents/MacOS/NeAntik Browser"))
        lock = json.loads((self.runtime / "fingerprint-chromium-15498.lock.json").read_text())
        self.assertEqual(lock["verification"]["coherentAppleDeviceTuples"], "pending-runtime-evidence")
        self.assertEqual(self.invoke(), 1)  # immutable frozen evidence

    def test_failed_final_verification_removes_partial_evidence(self):
        self.assertEqual(self.invoke(fail_lock=True), 1)
        for name in (
            "chromium-15498-source-snapshot.json",
            "chromium-15498-source-input-manifest.json",
            "chromium-15498-source-contract.json",
            "chromium-15498-port-candidate.json",
            "fingerprint-chromium-15498.lock.json",
        ):
            self.assertFalse((self.runtime / name).exists(), name)


if __name__ == "__main__":
    unittest.main()
