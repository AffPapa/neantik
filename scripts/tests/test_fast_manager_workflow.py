import importlib.util
from pathlib import Path
import tempfile
import unittest
import re

SPEC = importlib.util.spec_from_file_location("fast_manager", Path(__file__).resolve().parents[1] / "test-manager-fast.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FastManagerWorkflowTests(unittest.TestCase):
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
        for output in ["Build complete!", "Test run with 0 tests in 0 suites passed", "Test run failed"]:
            with self.assertRaises(ValueError): MOD.positive_result(output)
        self.assertEqual(MOD.positive_result("Test run with 17 tests in 2 suites passed"), {"tests": 17, "suites": 2})

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
