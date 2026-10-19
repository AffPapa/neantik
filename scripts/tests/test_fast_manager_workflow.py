import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import re
from unittest import mock

SPEC = importlib.util.spec_from_file_location("fast_manager", Path(__file__).resolve().parents[1] / "test-manager-fast.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FastManagerWorkflowTests(unittest.TestCase):
    def test_full_run_capability_failure_stops_before_cache_or_swift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "Package.swift").write_text("package")
            output = io.StringIO()
            with mock.patch.object(MOD, "ROOT", root), \
                    mock.patch.object(MOD, "suites", return_value=["OwnedTests"]), \
                    mock.patch.object(MOD, "full_run_capability_gaps", return_value=["loopback-tcp"]), \
                    mock.patch.object(MOD, "supervise") as run_swift, \
                    contextlib.redirect_stdout(output):
                self.assertEqual(MOD.main(["--all"]), 75)
            receipt = json.loads(output.getvalue())
            self.assertEqual(receipt["status"], "blocked")
            self.assertEqual(receipt["missingCapabilities"], ["loopback-tcp"])
            self.assertFalse(receipt["testsStarted"])
            run_swift.assert_not_called()
            self.assertFalse((root / ".build").exists())

    def test_full_run_with_capabilities_still_executes_and_records_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "Package.swift").write_text("package")
            def run_swift(_command, **kwargs):
                kwargs["stdout"].write("✔ Test owned() passed after 0.1 seconds.\n✔ Test run with 1 test in 1 suite passed\n".encode())
                return 0
            output = io.StringIO()
            with mock.patch.object(MOD, "ROOT", root), \
                    mock.patch.object(MOD, "suites", return_value=["OwnedTests"]), \
                    mock.patch.object(MOD, "full_run_capability_gaps", return_value=[]), \
                    mock.patch.object(MOD.subprocess, "check_output", return_value="/fixture/developer\n"), \
                    mock.patch.object(MOD, "supervise", side_effect=run_swift), \
                    contextlib.redirect_stdout(output):
                self.assertEqual(MOD.main(["--all"]), 0)
            receipt = json.loads(output.getvalue().splitlines()[0])
            self.assertEqual(receipt["status"], "pass")
            self.assertEqual(receipt["tests"], 1)

    def test_python_child_cannot_pollute_source_even_when_parent_enables_bytecode(self):
        # Exercise main's actual child environment without invoking Swift.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'Package.swift').write_text('fixture')
            helper = root / 'owned_import.py'; helper.write_text('value = 1\n')
            def child(_command, **kwargs):
                env = dict(kwargs['env'], PYTHONPATH=str(root))
                subprocess.run([sys.executable, '-c', 'import owned_import'], env=env, check=True)
                self.assertFalse((root / '__pycache__').exists())
                kwargs['stdout'].write(('✔ Test owned() passed after 0.1 seconds.\n'
                    '✔ Test run with 1 test in 1 suite passed\n').encode())
                return 0
            with mock.patch.object(MOD, 'ROOT', root), \
                    mock.patch.object(MOD, 'suites', return_value=['OwnedTests']), \
                    mock.patch.object(MOD.subprocess, 'check_output', return_value='/fixture/developer\n'), \
                    mock.patch.object(MOD, 'supervise', side_effect=child), \
                    mock.patch.dict(os.environ, {'PYTHONDONTWRITEBYTECODE': '0'}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(MOD.main(['--suite', 'OwnedTests']), 0)
            # Sensitivity control: the same import really generates a cache
            # when the new transitive protection is intentionally removed.
            env = dict(os.environ, PYTHONPATH=str(root), PYTHONDONTWRITEBYTECODE='0')
            subprocess.run([sys.executable, '-c', 'import owned_import'], env=env, check=True)
            self.assertTrue((root / '__pycache__').is_dir())

    def test_unknown_or_regex_suite_never_becomes_a_test_command(self):
        for suites in [[], ["MissingTests"], [".*"], ["ValidTests|OtherTests"], ["ValidTests", "MissingTests"]]:
            with self.assertRaises(ValueError):
                MOD.selection(suites, ["ValidTests"])

    def test_new_swift_suite_is_discovered_without_manual_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); tests = root / "Tests/NeAntikTests"; tests.mkdir(parents=True)
            (tests / "New.swift").write_text('@Suite("New mode") struct BrandNewTests {}')
            self.assertEqual(MOD.suites(root), ["BrandNewTests"])

    def test_empty_success_output_is_not_a_pass(self):
        for output in ["Build complete!", "Test run with 0 tests in 0 suites passed", "Test run failed",
                       "Test run with 17 tests in 2 suites passed",
                       "➜ Test requiresHardware() skipped: unavailable\n✔ Test run with 1 test in 1 suite passed"]:
            with self.assertRaises(ValueError): MOD.positive_result(output)
        self.assertEqual(MOD.positive_result("✔ Test works() passed after 0.1 seconds.\n➜ Test hardware() skipped: unavailable\n✔ Test run with 17 tests in 2 suites passed"),
                         {"tests": 17, "suites": 2, "passedTestLogLines": 1, "skippedTestLogLines": 1})

    def test_exact_swiftpm_warning_can_interrupt_a_real_success_summary(self):
        warning = ("warning: '--build-system native' has been deprecated and will be removed "
                   "in a future release; please report an issue at "
                   "https://github.com/swiftlang/swift-package-manager/issues if you are "
                   "unable to adopt the default build system.\n")
        body = "✔ Test owned() passed after 0.1 seconds.\n"
        interrupted = "✔ Test run with 22 tests in 1 suite" + warning + " passed after 0.2 seconds.\n"
        self.assertEqual(MOD.positive_result(body + interrupted),
            {"tests": 22, "suites": 1, "passedTestLogLines": 1, "skippedTestLogLines": 0})
        for absent_body in ["", "➜ Test owned() skipped: unavailable\n"]:
            with self.assertRaises(ValueError): MOD.positive_result(absent_body + interrupted)
        with self.assertRaises(ValueError):
            MOD.positive_result(body + interrupted.replace(" passed after", " failed after"))

    def test_unknown_interleaved_diagnostics_are_not_discarded(self):
        body = "✔ Test owned() passed after 0.1 seconds.\n"
        for diagnostic in ["warning: unrelated warning\n", "error: failed operation\n"]:
            interrupted = "✔ Test run with 22 tests in 1 suite" + diagnostic + " passed after 0.2 seconds.\n"
            with self.assertRaises(ValueError): MOD.positive_result(body + interrupted)

    def test_repeated_input_does_not_require_cold_cache_and_changed_input_changes_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "Package.swift").write_text("package")
            sources = root / "Sources"; sources.mkdir(); file = sources / "Logic.swift"; file.write_text("let value = 1")
            first = MOD.input_digest(root); self.assertEqual(first, MOD.input_digest(root))
            file.write_text("let value = 2"); self.assertNotEqual(first, MOD.input_digest(root))

    def test_cached_command_keeps_serial_jobs_and_cannot_skip_execution(self):
        args = MOD.command(Path("/repo"), Path("/repo/.build/neantik-local"), MOD.selection(["ValidTests"], ["ValidTests"]))
        self.assertIn("--no-parallel", args); self.assertEqual(args[args.index("--jobs") + 1], "2")
        self.assertNotIn("--skip-build", args); self.assertNotIn("--skip", args)

    def test_specifier_filter_matches_only_selected_suites(self):
        pattern = MOD.selection(["ValidTests", "OtherTests"], ["ValidTests", "OtherTests"])
        for specifier in ["NeAntikTests.ValidTests/testOne", "NeAntikTests.OtherTests/testTwo"]:
            self.assertIsNotNone(re.search(pattern, specifier))
        for specifier in ["NeAntikTests.NotValidTests/testOne", "NeAntikTests.ValidTestsExtra/testOne"]:
            self.assertIsNone(re.search(pattern, specifier))
