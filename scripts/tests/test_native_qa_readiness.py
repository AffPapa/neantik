import importlib.util
from pathlib import Path
import subprocess
import unittest

SPEC = importlib.util.spec_from_file_location(
    "native_qa_readiness", Path(__file__).resolve().parents[1] / "native-qa-readiness.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class NativeQAReadinessTests(unittest.TestCase):
    def test_normal_and_fair_allow_attempt_without_qualification(self):
        for thermal in (0, 1):
            report = MOD.assess(1, thermal)
            self.assertTrue(report["eligibleForAttempt"])
            self.assertEqual(MOD.exit_code(report), 0)
            self.assertEqual(report["status"], "not-run")
            self.assertFalse(report["releaseQualified"])

    def test_warning_and_critical_refuse_even_with_nominal_thermal(self):
        for pressure, reason in ((2, "memory_pressure_warning"), (4, "memory_pressure_critical")):
            report = MOD.assess(pressure, 0)
            self.assertFalse(report["eligibleForAttempt"])
            self.assertEqual(report["reasons"], [reason])
            self.assertEqual(MOD.exit_code(report), 75)

    def test_serious_and_critical_thermal_refuse_with_normal_memory(self):
        for thermal in (2, 3):
            self.assertEqual(MOD.exit_code(MOD.assess(1, thermal)), 75)

    def test_unknown_and_unsupported_values_never_allow_launch(self):
        for pressure, thermal in ((None, 0), (0, 0), (3, 0), (8, 0), (1, None), (1, -1), (1, 4)):
            report = MOD.assess(pressure, thermal)
            self.assertFalse(report["eligibleForAttempt"])
            self.assertEqual(MOD.exit_code(report), 78)

    def test_both_observers_are_read_once_and_no_launch_is_performed(self):
        calls = []
        def memory():
            calls.append("memory")
            return 1
        def thermal():
            calls.append("thermal")
            return 3 if calls.count("thermal") == 1 else 0
        report = MOD.observe("darwin", memory, thermal)
        self.assertEqual(calls, ["memory", "thermal"])
        self.assertEqual(report["reasons"], ["thermal_critical"])

    def test_sandbox_or_timeout_failure_is_unknown_and_does_not_print_raw_error(self):
        for error, classification in (
            (OSError(1, "private fixture path"), "permission_denied"),
            (subprocess.CalledProcessError(1, "private fixture command", stderr="Operation not permitted: private path"), "permission_denied"),
            (subprocess.TimeoutExpired("private fixture command", 5), "timeout"),
        ):
            def refused():
                raise error
            report = MOD.observe("darwin", refused, lambda: 0)
            self.assertEqual(report["reasons"], ["memory_pressure_unknown"])
            self.assertEqual(report["observerFailures"]["memoryPressure"], classification)
            self.assertNotIn("private fixture", str(report))

    def test_thermal_failure_does_not_hide_memory_warning(self):
        def refused():
            raise RuntimeError("private error")
        report = MOD.observe("darwin", lambda: 2, refused)
        self.assertEqual(report["reasons"], ["memory_pressure_warning", "thermal_unknown"])
        self.assertEqual(MOD.exit_code(report), 78)

    def test_non_macos_does_not_call_system_observers(self):
        def forbidden():
            self.fail("Must not call macOS observer")
        report = MOD.observe("linux", forbidden, forbidden)
        self.assertEqual(report["reasons"], ["macos_required"])
        self.assertFalse(report["eligibleForAttempt"])
