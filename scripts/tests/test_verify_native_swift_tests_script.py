from pathlib import Path
import re
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

    def test_ci_suite_runner_includes_signed_update_tests(self) -> None:
        text = SUITE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("UpdateManifestTests)", text)
        self.assertIn('--filter "$SUITE"', text)

    def test_ci_suite_runner_includes_authenticated_evidence_tests(
        self,
    ) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        runner = SUITE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("- FingerprintEvidenceEnvelopeTests", workflow)
        self.assertIn("FingerprintEvidenceEnvelopeTests|\\", runner)
        self.assertIn(
            "- SecureEnclaveFingerprintEvidenceSignerTests",
            workflow,
        )
        self.assertIn(
            "SecureEnclaveFingerprintEvidenceSignerTests|\\",
            runner,
        )

    def test_ci_matrix_suites_are_allowed_by_runner(self) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        runner = SUITE_SCRIPT.read_text(encoding="utf-8")
        matrix_suites = re.findall(
            r"^\s+- ([A-Za-z][A-Za-z0-9]+Tests)$",
            workflow,
            flags=re.MULTILINE,
        )

        self.assertGreater(len(matrix_suites), 0)
        for suite in matrix_suites:
            self.assertIn(suite, runner)

    def test_ci_runs_every_non_live_swift_suite_and_excludes_live_suites(
        self,
    ) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        runner = SUITE_SCRIPT.read_text(encoding="utf-8")
        matrix_suites = set(
            re.findall(
                r"^\s+- ([A-Za-z][A-Za-z0-9]+Tests)$",
                workflow,
                flags=re.MULTILINE,
            )
        )
        discovered_suites = {
            path.stem
            for path in SWIFT_TESTS.glob("*Tests.swift")
        }
        live_suites = {
            suite for suite in discovered_suites if suite.startswith("Live")
        }
        non_live_suites = discovered_suites - live_suites

        self.assertEqual(matrix_suites, non_live_suites)
        self.assertTrue(live_suites.isdisjoint(matrix_suites))
        for suite in non_live_suites:
            self.assertIn(suite, runner)

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
