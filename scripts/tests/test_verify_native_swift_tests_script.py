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
SHARD_SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-native-swift-shard.sh"
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

    def test_ci_suite_runner_excludes_removed_dormant_suites(self) -> None:
        text = SUITE_SCRIPT.read_text(encoding="utf-8")

        self.assertNotIn("UpdateManifestTests", text)
        self.assertNotIn("TelemetryTests", text)
        self.assertNotIn("RuntimePreferenceStoreTests", text)
        self.assertIn('--filter "$SUITE"', text)

    def test_ci_runs_four_isolated_swift_shards(self) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn(
            'run: ./scripts/verify-native-swift-shard.sh "${{ matrix.shard }}"',
            workflow,
        )
        for shard in ["foundation", "fingerprint", "profiles-a", "profiles-b"]:
            self.assertIn(f"- {shard}", workflow)

    def test_ci_shards_cover_every_non_live_suite_exactly_once(self) -> None:
        runner = SHARD_SCRIPT.read_text(encoding="utf-8")
        shard_suites = re.findall(
            r"^\s+([A-Za-z][A-Za-z0-9]+Tests)$",
            runner,
            flags=re.MULTILINE,
        )
        discovered_suites = {
            path.stem
            for path in SWIFT_TESTS.glob("*Tests.swift")
        }
        non_live_suites = {
            suite
            for suite in discovered_suites
            if not suite.startswith("Live")
        }

        self.assertEqual(len(shard_suites), len(set(shard_suites)))
        self.assertEqual(set(shard_suites), non_live_suites)
        self.assertIn('--filter "$SUITE"', runner)

    def test_ci_shard_runner_rejects_unknown_shard_before_building(self) -> None:
        result = subprocess.run(
            [str(SHARD_SCRIPT), "unknown"],
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("Unknown Swift test shard", result.stderr)

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
