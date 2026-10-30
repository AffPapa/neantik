from pathlib import Path
import json
import re
import importlib.util
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-native-swift-tests.sh"
RELEASE_SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-native-swift-release.sh"
)
SUITE_SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-native-swift-suite.sh"
)
LIVE_SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-native-swift-live.sh"
)
CI_WORKFLOW = (
    Path(__file__).resolve().parents[2]
    / ".github"
    / "workflows"
    / "ci.yml"
)
OPEN_SOURCE_VERIFIER = (
    Path(__file__).resolve().parents[1]
    / "verify-open-source-tree.py"
)
SWIFT_TESTS = Path(__file__).resolve().parents[2] / "Tests" / "NeAntikTests"
RUNTIME_FIXTURE_SUITES = Path(__file__).resolve().parents[1] / "swift-runtime-fixture-suites.json"

CI_SPEC = importlib.util.spec_from_file_location("ci_contract", SCRIPT.parent / "test-manager-ci.py")
CI_RUNNER = importlib.util.module_from_spec(CI_SPEC)
CI_SPEC.loader.exec_module(CI_RUNNER)


class NativeSwiftTestVerifierScriptTests(unittest.TestCase):
    def test_uses_isolated_writable_swift_caches(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("mktemp -d /private/tmp/nevision-swift-cache-XXXXXX", text)
        self.assertIn("SWIFTPM_HOME=\"$SWIFT_TEST_ROOT/swiftpm-home\"", text)
        self.assertIn("CLANG_MODULE_CACHE_PATH=\"$SWIFT_TEST_ROOT/module-cache\"", text)
        self.assertIn("--scratch-path \"$SWIFT_TEST_ROOT/build\"", text)

    def test_disables_swiftpm_sandbox_for_codex_managed_sandbox(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("swift test", text)
        self.assertIn("--disable-sandbox", text)

    def test_release_build_explicitly_targets_apple_silicon(self) -> None:
        text = RELEASE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("swift build", text)
        self.assertIn("--arch arm64", text)

    def test_cleanup_is_guarded_to_nevision_tmp_prefix(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("trap cleanup EXIT", text)
        self.assertIn("/private/tmp/nevision-swift-cache-*", text)
        self.assertIn("rm -rf \"$SWIFT_TEST_ROOT\"", text)

    def test_suite_runner_has_safe_opt_in_incremental_cache(self) -> None:
        text = SUITE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("NEANTIK_SWIFT_SUITE_CACHE_DIR", text)
        self.assertIn('EXPECTED_CACHE_ROOT="$PROJECT_DIR/.build"', text)
        self.assertIn('PERSISTENT_CACHE=1', text)
        self.assertIn('PERSISTENT_CACHE=0', text)
        self.assertIn('"$PERSISTENT_CACHE" == 0', text)

    def test_ci_suite_runner_includes_signed_update_tests(self) -> None:
        text = SUITE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("UpdateManifestTests|", text)
        self.assertIn('--filter "$SUITE"', text)

    def test_ci_shards_include_authenticated_evidence_and_use_separate_processes(self) -> None:
        chosen = CI_RUNNER.catalog()
        self.assertIn("FingerprintEvidenceEnvelopeTests", chosen)
        self.assertIn("SecureEnclaveFingerprintEvidenceSignerTests", chosen)
        workflow = CI_WORKFLOW.read_text()
        self.assertIn('shard: [0, 1, 2, 3]', workflow)
        self.assertIn('scripts/test-manager-ci.py', workflow)
        self.assertNotIn('Authenticated fingerprint evidence contract', workflow)
        self.assertIn("unittest discover -s scripts/tests", workflow)

    def test_ci_runs_every_non_live_swift_suite_and_excludes_live_suites(
        self,
    ) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        runner = SUITE_SCRIPT.read_text(encoding="utf-8")
        matrix_suites = set(CI_RUNNER.catalog())
        # A file may extend an existing suite or declare several suites.
        # Coverage follows actual types, never a guessed filename filter.
        discovered_suites = set()
        for path in SWIFT_TESTS.glob("*.swift"):
            discovered_suites.update(re.findall(r"\b(?:struct|class|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*Tests)\b", path.read_text()))
        live_suites = {
            suite for suite in discovered_suites if suite.startswith("Live")
        }
        # Explicit, wholly opt-in research suites require an owned headed
        # runtime or local socket fixtures; ordinary CI cannot claim those ran.
        fixtures = json.loads(RUNTIME_FIXTURE_SUITES.read_text())
        self.assertIsInstance(fixtures, dict)
        self.assertTrue(set(fixtures).issubset(discovered_suites))
        for suite, flags in fixtures.items():
            matches = []
            for path in SWIFT_TESTS.glob("*.swift"):
                source = path.read_text()
                declaration = re.search(r"\b(?:struct|class|actor|enum)\s+" + re.escape(suite) + r"\b", source)
                if declaration:
                    # Several suites may share one file; test gates belong to the
                    # actual suite, not a guessed basename or unrelated suite.
                    tail = source[declaration.end():]
                    tail = re.split(r"\n@Suite\b", tail, maxsplit=1)[0]
                    matches.append(tail)
            self.assertEqual(len(matches), 1)
            text = matches[0]
            declarations = re.findall(r"@Test([^\n]*)", text)
            self.assertGreater(len(declarations), 0)
            self.assertGreater(len(flags), 0)
            for flag in flags:
                self.assertRegex(flag, r"^NEANTIK_[A-Z_]+$")
                self.assertIn(f'["{flag}"]', text)
            for declaration in declarations:
                self.assertIn(".enabled(if:", declaration)
                self.assertTrue(any(f'environment["{flag}"]' in declaration for flag in flags))
        live_suites |= set(fixtures)
        non_live_suites = discovered_suites - live_suites

        self.assertEqual(matrix_suites, non_live_suites)
        self.assertTrue(live_suites.isdisjoint(matrix_suites))
        shards = [CI_RUNNER.partition(sorted(matrix_suites), i, 4) for i in range(4)]
        self.assertEqual(len([s for shard in shards for s in shard]), len(non_live_suites))

    def test_suite_runner_requires_a_positive_test_count(self) -> None:
        runner = SUITE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("Swift suite did not execute a positive test count", runner)
        self.assertRegex(
            runner,
            r"Test run with \[1-9\]\[0-9\]\* tests\?",
        )

    def test_live_runner_is_explicit_local_and_fail_closed(self) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        runner = LIVE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("NEANTIK_RUN_LIVE_BROWSER_MANAGER", runner)
        self.assertIn("LiveBrowserProcessManagerIntegrationTests", runner)
        self.assertIn("NEANTIK_RUN_LIVE_FINGERPRINT_AUDIT", runner)
        self.assertIn("LiveFingerprintAuditIntegrationTests", runner)
        self.assertIn(
            "Live Swift suite did not execute a positive test count",
            runner,
        )
        self.assertNotIn("verify-native-swift-live.sh", workflow)

    def test_live_runner_rejects_unknown_mode_before_building(self) -> None:
        result = subprocess.run(
            [str(LIVE_SCRIPT), "unknown"],
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("Unknown live verification mode", result.stderr)

    def test_process_inventory_source_and_tests_are_public_contracts(
        self,
    ) -> None:
        verifier = OPEN_SOURCE_VERIFIER.read_text(encoding="utf-8")

        self.assertIn(
            '"Sources/NeAntik/BrowserProcessInventory.swift"',
            verifier,
        )
        self.assertIn(
            '"Tests/NeAntikTests/BrowserProcessInventoryTests.swift"',
            verifier,
        )

if __name__ == "__main__":
    unittest.main()
