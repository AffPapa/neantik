import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "audit-git-history-secrets.py"
SPEC = importlib.util.spec_from_file_location("audit_git_history_secrets", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GitHistorySecretAuditTests(unittest.TestCase):
    def make_repo(self, root: Path) -> None:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "config", "user.name", "NeAntik Test"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(root), "config", "user.email", "test@example.invalid"],
            check=True,
        )

    def commit_all(self, root: Path, message: str) -> None:
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        subprocess.run(
            ["git", "-C", str(root), "commit", "-q", "-m", message],
            check=True,
        )

    def test_clean_history_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            (root / "README.md").write_text("public source\n", encoding="utf-8")
            self.commit_all(root, "clean")
            objects, blobs = MODULE.audit(root)
            self.assertGreaterEqual(objects, 3)
            self.assertEqual(blobs, 1)

    def test_deleted_private_key_still_fails_without_printing_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            leaked = "-----BEGIN " + "PRIVATE KEY-----\nnever-print-this-value\n"
            key = root / "signing.p8"
            key.write_text(leaked, encoding="utf-8")
            self.commit_all(root, "leak")
            key.unlink()
            (root / "README.md").write_text("clean now\n", encoding="utf-8")
            self.commit_all(root, "delete")
            with self.assertRaises(MODULE.HistorySecretAuditError) as context:
                MODULE.audit(root)
            message = str(context.exception)
            self.assertIn("signing.p8", message)
            self.assertNotIn("never-print-this-value", message)


if __name__ == "__main__":
    unittest.main()
