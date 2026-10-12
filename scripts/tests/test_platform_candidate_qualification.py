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
    def test_canvas_cli_is_invoked_with_its_actual_supported_contract(self):
        command = MODULE.verifier_command(Path("fixtures"), "verify.py", Path("capture.json"))
        self.assertEqual(command[1:], ["fixtures/verify.py", "capture.json"])
        self.assertEqual(MODULE.verifier_command(Path("fixtures"), "verify-webgl.py", Path("capture.json"))[-1], "--negative-controls")

    def test_success_exit_does_not_replace_a_verdict_or_negative_controls(self):
        self.assertFalse(MODULE.verdict_passes({"exitCode": 0}))
        self.assertFalse(MODULE.verdict_passes({"passed": False}))
        self.assertTrue(MODULE.verdict_passes({"passed": True, "negativeControls": [{"name": "broken-fixture", "rejected": True}]}, expected_controls=("broken-fixture",)))
        self.assertFalse(MODULE.verdict_passes({"passed": True, "negativeControls": [{"name": "broken-fixture", "rejected": False}]}))
        self.assertFalse(MODULE.verdict_passes({"status": "verified-scoped-platform-operations", "issues": ["failed"]}))

    def test_missing_empty_malformed_and_duplicate_control_evidence_is_not_pass(self):
        self.assertFalse(MODULE.verdict_passes({"passed": True}))
        for controls in ([], None, {}, 1, "pass", [True], [{}], [{"name": "n", "rejected": 1}],
                         [{"name": "n", "rejected": True}] * 2):
            with self.subTest(controls=controls):
                self.assertFalse(MODULE.verdict_passes({"passed": True, "negativeControls": controls}))

    def test_every_named_case_requires_all_its_controls_without_extras(self):
        for case, names in MODULE.EXPECTED_CONTROL_NAMES.items():
            with self.subTest(case=case):
                report = {"passed": True, "negativeControls": [{"name": n, "rejected": True} for n in names]}
                self.assertTrue(MODULE.verdict_passes(report, expected_controls=names))
                for index in range(len(names)):
                    bad = copy.deepcopy(report)
                    bad["negativeControls"].pop(index)
                    self.assertFalse(MODULE.verdict_passes(bad, expected_controls=names))
                report["negativeControls"].append({"name": "unknown-control", "rejected": True})
                self.assertFalse(MODULE.verdict_passes(report, expected_controls=names))
        for case, _, _, verifier, _, _ in MODULE.CASES:
            if case not in ("drawing", "webgpu-native", "platform-state", "voices", "webgpu-policy"):
                self.assertIn(case, MODULE.EXPECTED_CONTROL_NAMES)

    def test_drawing_controls_have_their_own_required_receipt(self):
        report = {"passed": True, "controls": {"positiveFixturePassed": True,
                  "behaviorNegativeControlsRejected": 6, "pngNegativeControlsRejected": 4,
                  "pngFilterColorPositiveControls": 10}}
        self.assertTrue(MODULE.verdict_passes(report, contract="drawing"))
        for key in report["controls"]:
            bad = copy.deepcopy(report)
            bad["controls"].pop(key)
            self.assertFalse(MODULE.verdict_passes(bad, contract="drawing"), key)
        report["controls"]["positiveFixturePassed"] = 1
        self.assertFalse(MODULE.verdict_passes(report, contract="drawing"))

    def test_independent_oracle_controls_are_bound_to_their_case(self):
        report = {"status": "verified-scoped-platform-operations", "issues": []}
        receipt = {"positiveControls": 2, "negativeControls": 20, "actualBrowser": False}
        self.assertTrue(MODULE.verdict_passes(report, contract="platform-state", control_receipt=receipt))
        self.assertFalse(MODULE.verdict_passes(report, contract="platform-state"))
        self.assertFalse(MODULE.verdict_passes(report, contract="webgpu-native", control_receipt=receipt))
        for key in receipt:
            bad = dict(receipt)
            bad.pop(key)
            self.assertFalse(MODULE.verdict_passes(report, contract="platform-state", control_receipt=bad), key)
        self.assertFalse(MODULE.verdict_passes(report, contract="unknown", control_receipt=receipt))

    def test_voice_timeout_is_inconclusive_without_qualifying_the_case(self):
        source = "a" * 64
        def observation(kind, availability, count):
            return {"sourceSHA256": source, "result": {"observation": kind, "availability": availability, "count": count}}
        for good in (observation("observed", "available", "0"), observation("observed", "available", "256"),
                     observation("unavailable", "unavailable", "unavailable")):
            verdict = MODULE.voices_verdict(good, source)
            self.assertTrue(MODULE.verdict_passes(verdict, contract="observation"))
        timeout = MODULE.voices_verdict(observation("timeout", "available", "unavailable"), source)
        self.assertEqual(timeout["status"], "inconclusive")
        self.assertTrue(timeout["captureValid"])
        self.assertFalse(timeout["passed"])
        self.assertFalse(MODULE.verdict_passes(dict(timeout, passed=True), contract="observation"))
        for count in (None, 1, True, "257", "-1", "1.0", "9" * 10000, "٢"):
            self.assertFalse(MODULE.voices_verdict(observation("observed", "available", count), source)["passed"])
        self.assertFalse(MODULE.voices_verdict({}, source)["passed"])
        self.assertFalse(MODULE.voices_verdict(observation("observed", "available", "1"), "b" * 64)["passed"])

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
