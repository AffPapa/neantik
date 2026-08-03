import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "verify-built-runtime.sh"


class VerifyBuiltRuntimeScriptTests(unittest.TestCase):
    def test_new_report_requires_source_provenance_schema_three(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('"schemaVersion": 3', script)
        self.assertIn("sourceContractSHA256", script)
        self.assertIn("sourceProvenanceSHA256", script)
        self.assertIn(
            "A new runtime report requires Chromium 150 source provenance.",
            script,
        )

    def test_generated_postimages_override_patch_group_intermediates(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("generated_postimages = {}", script)
        self.assertIn(
            "expected_sha256 = generated_postimages.get(",
            script,
        )
        self.assertLess(
            script.index("generated_postimages = {}"),
            script.index(
                "expected_sha256 = generated_postimages.get("
            ),
        )

    def test_report_contains_no_local_absolute_paths(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            '"path": os.environ["EXECUTABLE_BUNDLE_PATH"]',
            script,
        )
        self.assertIn(
            '"path": os.environ["FRAMEWORK_BUNDLE_PATH"]',
            script,
        )
        self.assertNotIn(
            '"path": os.environ["EXECUTABLE_PATH"]',
            script,
        )
        self.assertNotIn(
            '"path": os.environ["FRAMEWORK_PATH"]',
            script,
        )
        self.assertNotIn(
            '"path": os.environ["BUILD_ARGS_PATH"]',
            script,
        )

    def test_report_requires_and_binds_explicit_candidate_lock(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("CANDIDATE_LOCK_PATH", script)
        self.assertIn(
            "A new runtime report requires an explicit schema 4 candidate lock.",
            script,
        )
        self.assertIn(
            '"candidateLockSHA256": os.environ["CANDIDATE_LOCK_SHA256"]',
            script,
        )
        self.assertIn("verify-runtime-candidate-lock.py", script)

    def test_build_exports_candidate_after_provenance_before_binary_build(self) -> None:
        build = (
            PROJECT_ROOT / "scripts" / "build-runtime.sh"
        ).read_text(encoding="utf-8")

        provenance = build.index("export-runtime-source-provenance.py")
        candidate = build.index("export-runtime-candidate-lock.py")
        ninja = build.index("ninja -C out/Default")
        self.assertLess(provenance, candidate)
        self.assertLess(candidate, ninja)


if __name__ == "__main__":
    unittest.main()
