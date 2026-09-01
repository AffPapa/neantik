import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
PREPARE = SCRIPTS / "prepare-direct-runtime-candidate.sh"
PREPARE_MANAGER = SCRIPTS / "prepare-direct-manager-update.sh"
PACKAGE_APP = SCRIPTS / "package-app.sh"
RELEASE = SCRIPTS / "release-direct.sh"
NOTARIZE = SCRIPTS / "notarize-direct-candidate.sh"
NOTARY_TRANSACTION = SCRIPTS / "notarize_direct_transaction.py"
ENROLL = SCRIPTS / "enroll-direct-fingerprint-authority.sh"
INTEGRATED_VERIFIER = SCRIPTS / "verify-integrated-release.sh"
RELEASE_VERIFIER = SCRIPTS / "verify-release.sh"
PROFILE_VERIFIER = SCRIPTS / "verify-direct-provisioning-profile.py"
RELEASE_ENTITLEMENTS = SCRIPTS.parent / "Resources" / "NeAntik.entitlements"
RELEASE_ENTRYPOINTS = (
    SCRIPTS.parent / "Release-NeAntik.command",
    SCRIPTS / "Run-NeAntik-Release.command",
    SCRIPTS / "prepare-direct-runtime-candidate.sh",
    SCRIPTS / "prepare-direct-manager-update.sh",
    SCRIPTS / "release-direct.sh",
    SCRIPTS / "notarize-direct-candidate.sh",
    SCRIPTS / "release-direct-dmg.sh",
    SCRIPTS / "enroll-direct-fingerprint-authority.sh",
)


class ReleaseDirectScriptTests(unittest.TestCase):
    def test_release_entrypoints_use_private_umask_and_reviewed_path(self) -> None:
        expected_path = (
            'export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"'
        )
        for script in RELEASE_ENTRYPOINTS:
            with self.subTest(script=script.name):
                text = script.read_text(encoding="utf-8")
                self.assertIn("umask 077", text)
                self.assertIn(expected_path, text)
                self.assertLess(text.index("umask 077"), text.index("PROJECT_DIR="))

    def test_dmg_release_uses_absolute_apple_security_tools(self) -> None:
        text = (SCRIPTS / "release-direct-dmg.sh").read_text(
            encoding="utf-8"
        )
        for tool in (
            "/usr/bin/codesign",
            "/usr/bin/xcrun",
            "/usr/sbin/spctl",
            "/usr/bin/hdiutil",
            "/usr/bin/ditto",
            "/usr/bin/shasum",
            "/usr/bin/security",
        ):
            self.assertIn(tool, text)
        for bare in (
            "\ncodesign ",
            "\nxcrun ",
            "\nspctl ",
            "\nhdiutil ",
            "\nditto ",
            "\nsecurity ",
        ):
            self.assertNotIn(bare, text)

    def test_release_verifier_rejects_sandbox_and_dormant_network_surfaces(
        self,
    ) -> None:
        text = RELEASE_VERIFIER.read_text(encoding="utf-8")

        for key in (
            "NeAntikUpdateChannelEnabled",
            "NeAntikUpdateAutoDownload",
            "NeAntikUpdateManifestURL",
            "NeAntikUpdatePublicKeyID",
            "NeAntikUpdatePublicKeyBase64",
        ):
            self.assertNotIn(key, text)
        self.assertIn("verify-direct-telemetry-disabled.py", text)
        self.assertIn("verify-direct-update-policy.py", text)
        self.assertIn('--info-plist "$INFO_PLIST"', text)
        self.assertIn("verify-direct-provisioning-profile.py", text)
        self.assertIn("embedded.provisionprofile", text)
        self.assertIn("NEANTIK_LOCAL_ADHOC", text)
        self.assertIn("must not embed a distribution profile", text)
        sandbox_branch = text.split(
            "grep -q 'com.apple.security.app-sandbox'; then",
            1,
        )[1].split("fi", 1)[0]
        self.assertIn("Direct distribution forbids", sandbox_branch)
        self.assertIn("exit 65", sandbox_branch)
        self.assertNotIn("Mac App Store sandbox", text)

    def test_release_packaging_resolves_current_swift_bin_path(self) -> None:
        stale_path = ".build/arm64-apple-macosx/release/NeAntik"

        for script in (PACKAGE_APP, PREPARE_MANAGER):
            text = script.read_text(encoding="utf-8")
            self.assertIn("--show-bin-path", text)
            self.assertIn('MANAGER_BINARY="$BIN_PATH/NeAntik"', text)
            self.assertIn('cp "$MANAGER_BINARY"', text)
            self.assertNotIn(stale_path, text)

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
        self.assertIn("verify-built-runtime.sh", text)
        self.assertIn("promote-runtime-candidate-lock.py", text)
        self.assertIn("--confirm-promote-source-lock", text)
        self.assertIn("generate-runtime-integration-notices.py", text)
        self.assertIn("package-integrated-app.sh", text)
        self.assertIn("enroll-direct-fingerprint-authority.sh", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertIn("--fingerprint-enrollment", text)
        self.assertIn("/usr/bin/mktemp -d", text)
        self.assertIn("fingerprint-enrollment.XXXXXX", text)
        self.assertIn('APP_PATH="$PROJECT_DIR/dist/NeAntik.app"', text)
        self.assertNotIn("notarytool submit", text)
        self.assertLess(
            text.index("sign-runtime.sh"),
            text.index("verify-built-runtime.sh"),
        )
        self.assertLess(
            text.index("verify-built-runtime.sh"),
            text.index("promote-runtime-candidate-lock.py"),
        )
        self.assertLess(
            text.index("promote-runtime-candidate-lock.py"),
            text.index("package-integrated-app.sh"),
        )
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
        self.assertIn("NEANTIK_PROVISIONING_PROFILE", text)
        self.assertIn("verify-direct-provisioning-profile.py", text)
        self.assertIn('--entitlements "$RELEASE_ENTITLEMENTS"', text)
        self.assertLess(
            text.index('python3 "$PROJECT_DIR/scripts/verify-direct-provisioning-profile.py"', final_signing),
            enrollment,
        )
        self.assertIn("--fingerprint-enrollment", text)
        self.assertIn("/usr/bin/mktemp -d", text)
        self.assertIn("fingerprint-enrollment.XXXXXX", text)
        self.assertIn(
            "LOCAL QA ONLY: schema-3 release enrollment was intentionally skipped.",
            text,
        )

    def test_manager_only_update_preserves_verified_runtime_evidence(self) -> None:
        text = PREPARE_MANAGER.read_text(encoding="utf-8")

        self.assertIn("verify_reviewed_runtime_evidence", text)
        self.assertIn("verify-packaged-runtime-report.py", text)
        self.assertIn("verify-runtime-compliance.sh", text)
        self.assertIn("cmp -s", text)
        self.assertNotIn(
            '"$PROJECT_DIR/scripts/verify-built-runtime.sh" \\\n'
            '    "$CANDIDATE_RUNTIME" \\\n'
            '    "$evidence/runtime-verification.json"',
            text,
        )
        self.assertNotIn("rebind_runtime_compliance", text)

    def test_manager_only_update_preserves_russian_bundle_contract(self) -> None:
        prepare = PREPARE_MANAGER.read_text(encoding="utf-8")
        verifier = INTEGRATED_VERIFIER.read_text(encoding="utf-8")

        for resource in ("InfoPlist.strings", "Localizable.strings"):
            self.assertIn(
                f'"$PROJECT_DIR/Resources/ru.lproj/{resource}"',
                prepare,
            )
            self.assertIn(resource, verifier)
        self.assertIn(
            '"$CANDIDATE_APP/Contents/Resources/ru.lproj/"',
            prepare,
        )
        self.assertIn("CFBundleDevelopmentRegion", verifier)
        self.assertIn(
            '[[ "$ACTUAL_MANAGER_DEVELOPMENT_REGION" != "ru" ]]',
            verifier,
        )
        self.assertIn('cmp -s "$expected" "$packaged"', verifier)

    def test_integrated_release_enforces_component_size_budgets(self) -> None:
        text = INTEGRATED_VERIFIER.read_text(encoding="utf-8")

        self.assertIn("scripts/audit-app-size.py", text)
        self.assertIn("--check", text)
        self.assertLess(
            text.index("scripts/audit-app-size.py"),
            text.index('RUNTIME_PLIST="$RUNTIME_APP/Contents/Info.plist"'),
        )

    def test_enrollment_helper_is_exact_private_and_bounded(self) -> None:
        text = ENROLL.read_text(encoding="utf-8")

        self.assertIn("verify-active-gui-session-unlocked.py", text)
        self.assertIn("Authority=Developer ID Application:", text)
        self.assertIn("Timestamp=", text)
        self.assertIn("verify-direct-provisioning-profile.py", text)
        self.assertIn("embedded.provisionprofile", text)
        self.assertIn("run-exact-command-with-timeout.py", text)
        self.assertIn("--timeout 60", text)
        self.assertIn("--neantik-enroll-fingerprint-evidence", text)
        self.assertIn("--output \"$OUTPUT_PATH\"", text)
        self.assertLess(
            text.index("verify-active-gui-session-unlocked.py"),
            text.index("--neantik-enroll-fingerprint-evidence"),
        )
        self.assertNotIn("cat \"$LOG_PATH\"", text)
        self.assertNotIn("open -", text)

    def test_release_entitlements_and_profile_gate_are_exact(self) -> None:
        entitlements = RELEASE_ENTITLEMENTS.read_text(encoding="utf-8")
        verifier = PROFILE_VERIFIER.read_text(encoding="utf-8")

        self.assertIn("H6VGU2M6JD.app.neantik.desktop", entitlements)
        self.assertIn("keychain-access-groups", entitlements)
        self.assertNotIn("get-task-allow", entitlements)
        self.assertNotIn("com.apple.security.app-sandbox", entitlements)
        for marker in (
            "ProvisionsAllDevices",
            "ProvisionedDevices",
            "ExpirationDate",
            "TeamIdentifier",
            "DeveloperCertificates",
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "Authority=Developer ID Application:",
            "Timestamp=",
        ):
            self.assertIn(marker, verifier)

        for script in (PREPARE, PREPARE_MANAGER):
            text = script.read_text(encoding="utf-8")
            self.assertIn("NEANTIK_PROVISIONING_PROFILE", text)
            self.assertIn("verify-direct-provisioning-profile.py", text)
            self.assertIn('--entitlements "$RELEASE_ENTITLEMENTS"', text)
            self.assertIn(
                '--signing-identity "$NEANTIK_SIGNING_IDENTITY"',
                text,
            )

    def test_release_only_verifies_and_notarizes_prepared_candidate(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertIn("NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?", text)
        self.assertIn("NEANTIK_RELEASE_CHANNEL", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertEqual(text.count("direct-candidate-manifest.py"), 1)
        self.assertIn("run-isolated-release-python.py", text)
        self.assertEqual(
            text.count("run-isolated-release-python.py"),
            4,
        )
        self.assertIn("verify-browser-identity-issuance.py", text)
        self.assertIn("notary_transaction_inspector.py", text)
        self.assertIn("--release-gate", text)
        self.assertIn("--expected-archive-name", text)
        self.assertIn("EXPECTED_ARCHIVE=", text)
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
            text.index("verify-browser-identity-issuance.py"),
            text.index("direct-candidate-manifest.py"),
        )
        self.assertLess(
            text.index("direct-candidate-manifest.py"),
            text.index("notary_transaction_inspector.py"),
        )
        self.assertLess(
            text.index("notary_transaction_inspector.py"),
            text.index("notarize-direct-candidate.sh"),
        )

    def test_notarization_requires_authenticated_schema8_evidence(self) -> None:
        wrapper = NOTARIZE.read_text(encoding="utf-8")
        text = NOTARY_TRANSACTION.read_text(encoding="utf-8")
        fresh = text.split("def run_transaction(", 1)[1]

        self.assertIn("verify-fingerprint-evidence-envelope.py", text)
        self.assertIn("snapshot_candidate_inputs", text)
        self.assertIn("--integrated-app", text)
        self.assertIn("observe_sealed_phase", text)
        self.assertIn('"notarytool",\n                    "submit"', text)
        self.assertIn('"notarytool",\n                "info"', text)
        self.assertIn('"stapler", "staple", str(staged_app)', text)
        self.assertIn("publish_or_adopt_sealed_file", text)
        self.assertIn('"submit-intent"', text)
        self.assertIn('"submission-known"', text)
        self.assertIn('"sidecar-committed"', text)
        self.assertIn('"zip-committed"', text)
        self.assertIn('"publication-complete"', text)
        self.assertIn("release_source_receipt", text)
        self.assertIn('"--no-wait"', text)
        self.assertIn('"notarytool",\n                    "wait"', text)
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
        self.assertIn("--source-binding", wrapper)
        self.assertIn("direct-candidate-source.json", wrapper)
        self.assertIn("run-isolated-release-python.py", wrapper)
        self.assertIn("git -C \"$PROJECT_DIR\" ls-files -z -- '*.py'", wrapper)
        self.assertIn('python_cache="$python_parent/__pycache__"', wrapper)
        self.assertIn('find "$python_cache" -depth -delete', wrapper)
        self.assertNotIn('find "$PROJECT_DIR/scripts"', wrapper)
        self.assertIn("/opt/homebrew/bin/python3", wrapper)
        self.assertIn("Python 3.11", wrapper)
        self.assertLess(
            fresh.index("submission ZIP packaging"),
            fresh.index('"notarytool",\n                    "submit"'),
        )
        self.assertLess(
            fresh.index('"notarytool",\n                    "submit"'),
            fresh.index('"stapler", "staple", str(staged_app)'),
        )
        self.assertLess(
            fresh.index('"stapler", "staple", str(staged_app)'),
            fresh.index("final ZIP packaging"),
        )
        self.assertLess(
            fresh.index("final notarized archive verification"),
            fresh.index("publish_or_adopt_sealed_file"),
        )


if __name__ == "__main__":
    unittest.main()
