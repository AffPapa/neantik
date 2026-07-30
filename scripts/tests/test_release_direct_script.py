import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
PREPARE = SCRIPTS / "prepare-direct-runtime-candidate.sh"
PREPARE_MANAGER = SCRIPTS / "prepare-direct-manager-update.sh"
RELEASE = SCRIPTS / "release-direct.sh"
NOTARIZE = SCRIPTS / "notarize-direct-candidate.sh"
NOTARY_TRANSACTION = SCRIPTS / "notarize_direct_transaction.py"
ENROLL = SCRIPTS / "enroll-direct-fingerprint-authority.sh"


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
        self.assertIn("enroll-direct-fingerprint-authority.sh", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertIn("--fingerprint-enrollment", text)
        self.assertIn("/usr/bin/mktemp -d", text)
        self.assertIn("fingerprint-enrollment.XXXXXX", text)
        self.assertIn('APP_PATH="$PROJECT_DIR/dist/NeAntik.app"', text)
        self.assertNotIn("notarytool submit", text)
        self.assertLess(
            text.index("enroll-direct-fingerprint-authority.sh"),
            text.index("direct-candidate-manifest.py"),
        )

    def test_manager_candidate_enrolls_only_after_final_signature(self) -> None:
        text = PREPARE_MANAGER.read_text(encoding="utf-8")
        enrollment = text.index(
            "enroll-direct-fingerprint-authority.sh"
        )
        manifest = text.index("direct-candidate-manifest.py")
        final_signing = text.rindex("codesign \\\n")

        self.assertLess(final_signing, enrollment)
        self.assertLess(enrollment, manifest)
        self.assertIn("--fingerprint-enrollment", text)
        self.assertIn("/usr/bin/mktemp -d", text)
        self.assertIn("fingerprint-enrollment.XXXXXX", text)
        self.assertIn(
            "LOCAL QA ONLY: schema-3 release enrollment was intentionally skipped.",
            text,
        )

    def test_enrollment_helper_is_exact_private_and_bounded(self) -> None:
        text = ENROLL.read_text(encoding="utf-8")

        self.assertIn('stat -f \'%u\' /dev/console', text)
        self.assertIn('launchctl print "gui/$EUID"', text)
        self.assertIn("Authority=Developer ID Application:", text)
        self.assertIn("Timestamp=", text)
        self.assertIn("run-exact-command-with-timeout.py", text)
        self.assertIn("--timeout 60", text)
        self.assertIn("--neantik-enroll-fingerprint-evidence", text)
        self.assertIn("--output \"$OUTPUT_PATH\"", text)
        self.assertNotIn("cat \"$LOG_PATH\"", text)
        self.assertNotIn("open -", text)

    def test_release_only_verifies_and_notarizes_prepared_candidate(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertIn("NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?", text)
        self.assertIn("NEANTIK_RELEASE_CHANNEL", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertEqual(text.count("direct-candidate-manifest.py"), 1)
        self.assertIn("notarize-direct-candidate.sh", text)
        self.assertNotIn("verify-direct-notarized-archive.py", text)
        self.assertIn(
            "verify-direct-notarized-archive.py",
            NOTARY_TRANSACTION.read_text(encoding="utf-8"),
        )
        self.assertNotIn("sign-runtime.sh", text)
        self.assertNotIn("package-integrated-app.sh", text)
        self.assertNotIn("codesign --force", text)
        self.assertNotIn("rm -rf", text)
        self.assertLess(
            text.index("direct-candidate-manifest.py"),
            text.index("notarize-direct-candidate.sh"),
        )

    def test_notarization_requires_authenticated_schema8_evidence(self) -> None:
        wrapper = NOTARIZE.read_text(encoding="utf-8")
        text = NOTARY_TRANSACTION.read_text(encoding="utf-8")

        self.assertIn("verify-fingerprint-evidence-envelope.py", text)
        self.assertIn("snapshot_candidate_inputs", text)
        self.assertIn("--integrated-app", text)
        self.assertIn("observe_sealed_phase", text)
        self.assertIn('"notarytool",\n                    "submit"', text)
        self.assertIn('"notarytool",\n                "info"', text)
        self.assertIn('"stapler", "staple", str(staged_app)', text)
        self.assertIn("publish_release_pair", text)
        self.assertIn('"publicationState": "transaction-verified"', text)
        self.assertIn("refusing overwrite", text)
        self.assertIn("Authority=Developer ID Application:", text)
        self.assertIn("Timestamp=", text)
        self.assertIn("verify-runtime-security-baseline.py", text)
        self.assertIn("--allow-public-alpha-tuples", text)
        self.assertIn("verify-runtime-security-reference.py", text)
        self.assertIn("verify-direct-update-policy.py", text)
        self.assertIn("verify-public-fingerprint-corpus.py", text)
        self.assertNotIn("verify-gui-fingerprint-report.py", text)
        self.assertNotIn("rm -f", wrapper)
        self.assertNotIn("notarytool submit", wrapper)
        self.assertNotIn("stapler", wrapper)
        self.assertIn("notarize_direct_transaction.py", wrapper)
        self.assertLess(
            text.index("submission ZIP packaging"),
            text.index('"notarytool",\n                    "submit"'),
        )
        self.assertLess(
            text.index('"notarytool",\n                    "submit"'),
            text.index('"stapler", "staple", str(staged_app)'),
        )
        self.assertLess(
            text.index('"stapler", "staple", str(staged_app)'),
            text.index("final ZIP packaging"),
        )
        self.assertLess(
            text.index("final notarized archive verification"),
            text.index("publish_release_pair"),
        )


if __name__ == "__main__":
    unittest.main()
