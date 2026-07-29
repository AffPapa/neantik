import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "resume-prepared-chromium-150-build.sh"


class ResumePreparedChromium150BuildScriptTests(unittest.TestCase):
    def test_resume_script_does_not_rerun_source_mutation_steps(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("Resume an already prepared NeAntik Chromium 150 source tree", text)
        self.assertNotIn("retrieve_and_unpack_resource.sh", text)
        self.assertNotIn("prune_binaries.py", text)
        self.assertNotIn("patches.py", text)
        self.assertNotIn("domain_substitution.py", text)

    def test_resume_script_fails_closed_before_ninja_without_metal(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")

        metal_check = 'if ! xcrun metal -v >/dev/null 2>&1 || ! xcrun --find metallib >/dev/null 2>&1; then'
        self.assertIn(metal_check, text)
        self.assertIn("xcodebuild -downloadComponent MetalToolchain", text)
        self.assertIn("exit 69", text)
        self.assertLess(text.index(metal_check), text.index("ninja -C out/Default"))

    def test_resume_script_preserves_release_build_contract(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('target_cpu[[:space:]]*=[[:space:]]*"arm64"', text)
        self.assertIn("chrome_pgo_phase", text)
        self.assertIn("NEANTIK_NINJA_JOBS", text)
        self.assertIn("JOBS > 12", text)
        self.assertIn("gn\" gen out/Default --fail-on-unused-args", text)
        self.assertIn('ninja -C out/Default -j"$JOBS" chrome', text)

    def test_resume_script_patches_metal_module_cache_into_writable_tmp(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("NEANTIK_METAL_MODULE_CACHE", text)
        self.assertIn("third_party/angle/src/libANGLE/renderer/metal/BUILD.gn", text)
        self.assertIn("-fmodules-cache-path=", text)
        self.assertLess(text.index("-fmodules-cache-path="), text.index("gn\" gen out/Default"))


if __name__ == "__main__":
    unittest.main()
