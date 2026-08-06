from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
DEPLOY = ROOT / "ops" / "affpapa" / "server" / "neantik-release-deploy"


class DeployTransactionTests(unittest.TestCase):
    def test_any_failure_after_backup_uses_central_rollback_trap(self) -> None:
        text = DEPLOY.read_text(encoding="utf-8")

        self.assertIn("set -Eeuo pipefail", text)
        self.assertIn("cleanup_and_maybe_rollback()", text)
        self.assertIn("trap cleanup_and_maybe_rollback EXIT", text)
        self.assertIn('"$DEPLOY_ARMED" -eq 1', text)
        self.assertIn('"$DEPLOY_COMPLETE" -eq 0', text)
        self.assertIn("if ! do_rollback; then", text)
        self.assertLess(
            text.index("DEPLOY_ARMED=1"),
            text.index("# --- Activate page data, then release.json as the atomic public pointer ---"),
        )
        self.assertLess(
            text.index("DEPLOY_COMPLETE=1"),
            text.index("DEPLOY_ARMED=0", text.index("DEPLOY_COMPLETE=1")),
        )

    def test_rollback_is_disarmed_after_successful_restore(self) -> None:
        text = DEPLOY.read_text(encoding="utf-8")
        rollback = text[text.index("do_rollback() {"):text.index("publish_file() {")]

        self.assertIn("ROLLBACK_RUNNING=1", rollback)
        self.assertIn("DEPLOY_ARMED=0", rollback)
        self.assertIn("ROLLBACK_RUNNING=0", rollback)


if __name__ == "__main__":
    unittest.main()
