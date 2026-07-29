import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
PREPARE = SCRIPTS / "prepare-direct-runtime-candidate.sh"
RELEASE = SCRIPTS / "release-direct.sh"


class ReleaseDirectScriptTests(unittest.TestCase):
    def test_prepare_builds_and_binds_one_exact_candidate(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        self.assertIn('CANDIDATE_LOCK="$4"', text)
        self.assertIn("--source-root \"$SOURCE_ROOT\"", text)
        self.assertIn("--lock \"$CANDIDATE_LOCK\"", text)
        self.assertIn("angle_enable_metal=true", text)
        self.assertIn("verify-runtime-source-provenance.py", text)
        self.assertIn("verify-runtime-candidate-lock.py", text)
        self.assertIn("verify-runtime-security-baseline.py", text)
        self.assertIn("verify-direct-version-bump.py", text)
        self.assertIn("verify-direct-telemetry-disabled.py", text)
        self.assertIn("verify-direct-update-policy.py", text)
        self.assertIn("verify-public-fingerprint-corpus.py", text)
        self.assertIn("sign-runtime.sh", text)
        self.assertIn("package-integrated-app.sh", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertIn('APP_PATH="$PROJECT_DIR/dist/NeAntik.app"', text)
        self.assertNotIn("notarytool submit", text)

    def test_release_only_verifies_and_notarizes_prepared_candidate(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertIn("NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?", text)
        self.assertIn("NEANTIK_RELEASE_CHANNEL", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertGreaterEqual(text.count("direct-candidate-manifest.py"), 2)
        self.assertIn("notarize-direct-candidate.sh", text)
        self.assertIn("verify-direct-notarized-archive.py", text)
        self.assertNotIn("sign-runtime.sh", text)
        self.assertNotIn("package-integrated-app.sh", text)
        self.assertNotIn("codesign --force", text)
        self.assertNotIn("rm -rf", text)
        self.assertLess(
            text.index("direct-candidate-manifest.py"),
            text.index("notarize-direct-candidate.sh"),
        )


if __name__ == "__main__":
    unittest.main()
