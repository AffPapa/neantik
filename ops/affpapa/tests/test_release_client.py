from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
CLIENT = ROOT / "scripts" / "neantik-affpapa-release"
DISPATCHER = ROOT / "ops" / "affpapa" / "server" / "neantik-ssh-dispatcher"
SUDOERS = ROOT / "ops" / "affpapa" / "neantik-deploy.sudoers"


class ReleaseClientTests(unittest.TestCase):
    def test_publish_verifies_bytes_before_metadata_activation(self) -> None:
        text = CLIENT.read_text(encoding="utf-8")
        publish = text[
            text.index("publish_staged_release()"):
            text.index("direct_doctor()")
        ]

        self.assertLess(
            publish.index("verify_github_release"),
            publish.index("--stage-artifacts"),
        )
        self.assertLess(
            publish.index("verify_hosted_artifacts"),
            publish.index("--activate"),
        )
        self.assertIn("verify_live", publish)
        self.assertIn("neantik-release-rollback", publish)

    def test_full_hosted_gate_checks_hash_signature_and_gatekeeper(self) -> None:
        text = CLIENT.read_text(encoding="utf-8")
        self.assertIn("shasum -a 256", text)
        self.assertIn("verify-direct-notarized-dmg.sh", text)
        self.assertIn("verify-direct-notarized-archive.py", text)
        self.assertIn(
            "verify-direct-release-local-policy-fallback.py",
            text,
        )
        self.assertIn('artifact["url"] + ".sha256"', text)
        self.assertIn('artifact["filename"] + ".sha256"', text)
        self.assertIn("gh release download", text)
        self.assertIn("repos/AffPapa/neantik/commits/$tag", text)

    def test_local_policy_fallback_is_limited_to_known_macos_errors(self) -> None:
        text = CLIENT.read_text(encoding="utf-8")
        fallback = text[
            text.index("verify_release_artifacts_with_policy_fallback()"):
            text.index("verify_artifact_files_against_manifest()")
        ]
        self.assertIn("kLSDataUnavailableErr", fallback)
        self.assertIn("LSDataUnavailable", fallback)
        self.assertIn("internal error in code signing subsystem", fallback)
        self.assertIn("return 1", fallback)

    def test_macos_mktemp_templates_end_with_xxxxxx(self) -> None:
        text = CLIENT.read_text(encoding="utf-8")
        for line in text.splitlines():
            if "mktemp " in line and "XXXXXX" in line:
                template = line.split("XXXXXX", 1)[1]
                self.assertNotIn(".json", template)

    def test_live_metadata_verification_bypasses_stale_cdn_cache(self) -> None:
        text = CLIENT.read_text(encoding="utf-8")
        live = text[text.index("verify_live_metadata()"):text.index("verify_live()")]
        self.assertIn("release.json?release_gate=$cache_bust", live)
        self.assertIn("content.json?release_gate=$cache_bust", live)

    def test_restricted_channel_allows_only_exact_two_phase_commands(self) -> None:
        dispatcher = DISPATCHER.read_text(encoding="utf-8")
        sudoers = SUDOERS.read_text(encoding="utf-8")
        for mode in ("--stage-artifacts", "--activate"):
            self.assertIn(
                f'"neantik-release-deploy {mode}"',
                dispatcher,
            )
            self.assertIn(
                f"/usr/local/sbin/neantik-release-deploy {mode}",
                sudoers,
            )

    def test_doctor_compares_root_owned_server_ops_manifest(self) -> None:
        client = CLIENT.read_text(encoding="utf-8")
        status = (
            ROOT
            / "ops"
            / "affpapa"
            / "server"
            / "neantik-release-status"
        ).read_text(encoding="utf-8")
        installer = (
            ROOT / "ops" / "affpapa" / "install-server-batch.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("verify_remote_ops_contract", client)
        self.assertIn("remote.get(\"files\") == expected", client)
        self.assertIn("Ops manifest:", status)
        self.assertIn("/etc/neantik-release-ops.json", installer)

    def test_default_doctor_is_github_only_and_site_is_explicit(self) -> None:
        client = CLIENT.read_text(encoding="utf-8")
        direct = client[
            client.index("direct_doctor()"):
            client.index("site_doctor()")
        ]
        dispatch = client[client.index("main() {"):]

        self.assertIn("gh auth status", direct)
        self.assertIn("gh release view", direct)
        self.assertIn("GitHub-only doctor", direct)
        self.assertNotIn("preflight_access", direct)
        self.assertIn(
            "site-doctor|status|check|dry-run|abort|prepare|publish",
            dispatch,
        )
        self.assertIn("preflight_access", dispatch)


if __name__ == "__main__":
    unittest.main()
