from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-native-swift-tests.sh"


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
if __name__ == "__main__":
    unittest.main()
