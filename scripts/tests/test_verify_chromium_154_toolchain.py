import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify-chromium-154-toolchain.py"
spec = importlib.util.spec_from_file_location("verify_chromium_154_toolchain", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Chromium154ToolchainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = json.loads((ROOT / "runtime/chromium-154-toolchain-lock.json").read_text())
        cls.observed = {
            key: cls.lock["toolchain"][key]
            for key in ("xcodeVersion", "xcodeBuild", "sdkVersion", "sdkBuild", "clangVersion", "metalVersion", "metalBuild")
        }
        cls.args_gn = "target_os = \"mac\"\nuse_system_xcode = true\n"

    def test_exact_identity_passes_but_never_qualifies_release(self):
        developer_dir = self.lock["toolchain"]["developerDirectory"]
        report = module.verify(self.lock, self.observed, developer_dir, self.args_gn)
        self.assertTrue(report["verified"])
        self.assertFalse(report["releaseQualified"])
        self.assertFalse(report["hermetic"])
        self.assertFalse(report["identity"]["developerDirectory"].startswith("/"))

    def test_toolchain_version_mismatch_fails_closed(self):
        observed = dict(self.observed, xcodeBuild="different")
        developer_dir = self.lock["toolchain"]["developerDirectory"]
        report = module.verify(self.lock, observed, developer_dir, self.args_gn)
        self.assertFalse(report["verified"])
        self.assertIn("xcodeBuild mismatch", report["mismatches"])
        self.assertFalse(report["releaseQualified"])

    def test_sdk_and_metal_mismatch_fail_closed(self):
        observed = dict(self.observed, sdkBuild="wrong", metalBuild="wrong")
        developer_dir = self.lock["toolchain"]["developerDirectory"]
        report = module.verify(self.lock, observed, developer_dir, self.args_gn)
        self.assertFalse(report["verified"])
        self.assertIn("sdkBuild mismatch", report["mismatches"])
        self.assertIn("metalBuild mismatch", report["mismatches"])

    def test_wrong_process_scoped_developer_dir_fails_closed(self):
        expected = self.lock["toolchain"]["developerDirectory"]
        wrong = "/Applications/Xcode.app/Contents/Developer" if expected.endswith("Xcode-beta.app/Contents/Developer") else "/Applications/Xcode-beta.app/Contents/Developer"
        report = module.verify(self.lock, self.observed, wrong, self.args_gn)
        self.assertFalse(report["verified"])
        self.assertIn("process-scoped DEVELOPER_DIR mismatch", report["mismatches"])
        self.assertEqual("mismatch", report["identity"]["developerDirectory"])

    def test_gn_missing_or_false_fails_closed(self):
        for args_gn in (None, "use_system_xcode = false\n", "use_system_xcode = true\nuse_system_xcode = true\n"):
            with self.subTest(args_gn=args_gn):
                developer_dir = self.lock["toolchain"]["developerDirectory"]
                report = module.verify(self.lock, self.observed, developer_dir, args_gn)
                self.assertFalse(report["verified"])
                self.assertFalse(report["releaseQualified"])

    def test_lock_explicitly_never_claims_hermetic_or_release_qualified(self):
        self.assertTrue(self.lock["toolchain"]["systemXcode"])
        self.assertFalse(self.lock["toolchain"]["hermetic"])
        self.assertFalse(self.lock["toolchain"]["releaseQualified"])


if __name__ == "__main__":
    unittest.main()
