from pathlib import Path
import re
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-native-swift-tests.sh"
SUITE_SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-native-swift-suite.sh"
)
CI_WORKFLOW = (
    Path(__file__).resolve().parents[2]
    / ".github"
    / "workflows"
    / "ci.yml"
)


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

if __name__ == "__main__":
    unittest.main()
