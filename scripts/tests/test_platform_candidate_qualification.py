import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "runtime-platform/qualify-candidate.py"
SPEC = importlib.util.spec_from_file_location("platform_candidate_qualification", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PlatformQualificationTests(unittest.TestCase):
    def test_success_exit_does_not_replace_a_verdict_or_negative_controls(self):
        self.assertFalse(MODULE.verdict_passes({"exitCode": 0}))
        self.assertFalse(MODULE.verdict_passes({"passed": False}))
        self.assertTrue(MODULE.verdict_passes({"passed": True, "negativeControls": [{"rejected": True}]}))
        self.assertFalse(MODULE.verdict_passes({"passed": True, "negativeControls": [{"rejected": False}]}))
        self.assertFalse(MODULE.verdict_passes({"status": "verified-scoped-platform-operations", "issues": ["failed"]}))

    def test_independent_runtime_binding_rejects_missing_or_wrong_receipts(self):
        binding = {"runtimeVersion": "156.0.8078.12", "runtimeExecutableSHA256": "a" * 64,
                   "runtimeFrameworkSHA256": "b" * 64}
        good = {"runtimeVersion": binding["runtimeVersion"], "executableSHA256": "a" * 64,
                "runtimeFrameworkSHA256": "b" * 64, "headed": True, "cleanupVerified": True,
                "documentEvidence": {"loaded": True}}
        self.assertTrue(MODULE.capture_binding_matches(good, binding))
        for field in good:
            bad = copy.deepcopy(good)
            bad.pop(field)
            self.assertFalse(MODULE.capture_binding_matches(bad, binding), field)
        bad = dict(good, runtimeFrameworkSHA256="c" * 64)
        self.assertFalse(MODULE.capture_binding_matches(bad, binding))

    def test_real_capture_requires_frame_processing_revocation_denial_and_cleanup(self):
        good = {"kind": "synthetic-media-capture", "errors": [], "cleanupVerified": True,
                "before": {"camera": "granted", "microphone": "granted"},
                "tracks": [{"kind": "video", "state": "live"}, {"kind": "audio", "state": "live"}],
                "frame": {"presented": True, "nonzeroColor": True, "width": 640, "height": 480},
                "audio": {"finite": True, "frames": 256, "channels": 1, "callbacks": 1},
                "revoked": {"camera": "denied", "microphone": "denied", "events": 2},
                "denied": {"rejected": True, "error": "NotAllowedError"}}
        verdict = MODULE.checked_media_verdict(good)
        self.assertTrue(verdict["passed"])
        self.assertEqual(len(verdict["negativeControls"]), 5)
        self.assertTrue(all(c["rejected"] for c in verdict["negativeControls"]))
        for key in good:
            bad = copy.deepcopy(good)
            bad.pop(key)
            self.assertFalse(MODULE.media_verdict(bad)["passed"], key)
        # Failed captures must produce FAIL, not crash the verifier itself.
        self.assertFalse(MODULE.checked_media_verdict({"errors": ["timeout"]})["passed"])

    def test_immutable_resume_inputs_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "binding.json"
            MODULE.write_once(target, {"input": "original"})
            MODULE.write_once(target, {"input": "original"})
            with self.assertRaises(ValueError):
                MODULE.write_once(target, {"input": "changed"})


if __name__ == "__main__":
    unittest.main()
