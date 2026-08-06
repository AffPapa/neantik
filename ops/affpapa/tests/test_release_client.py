from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
CLIENT = ROOT / "scripts" / "neantik-affpapa-release"
DISPATCHER = ROOT / "ops" / "affpapa" / "server" / "neantik-ssh-dispatcher"
SUDOERS = ROOT / "ops" / "affpapa" / "neantik-deploy.sudoers"


class ReleaseClientTests(unittest.TestCase):
    def test_publish_verifies_bytes_before_metadata_activation(self) -> None:
        text = CLIENT.read_text(encoding="utf-8")
        publish = text[text.index("        publish)"):text.index("        upload)")]

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
        self.assertIn("gh release download", text)
        self.assertIn("repos/AffPapa/neantik/commits/$tag", text)

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


if __name__ == "__main__":
    unittest.main()
