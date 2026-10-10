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
            [
                "git",
                "-C",
                str(root),
                "config",
                "user.email",
                "test@example.invalid",
            ],
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

    def test_shallow_clone_cannot_claim_complete_history(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "source"
            self.make_repo(root)
            (root / "README.md").write_text("gh" + "p_" + "s" * 30)
            self.commit_all(root, "synthetic historical secret")
            (root / "README.md").write_text("clean tip")
            self.commit_all(root, "remove synthetic secret")
            clone = base / "shallow"
            subprocess.run(["git", "clone", "-q", "--depth=1", root.as_uri(), str(clone)], check=True)
            with self.assertRaisesRegex(MODULE.HistorySecretAuditError, "shallow"):
                MODULE.audit(clone)
            with self.assertRaisesRegex(MODULE.HistorySecretAuditError, "GitHub token"):
                MODULE.audit(root)

    def test_historical_forbidden_filename_survives_identical_blob_rename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            (root / ".env").write_text("unrecognized-provider-fixture\n")
            self.commit_all(root, "historical forbidden filename")
            (root / ".env").rename(root / "README.md")
            self.commit_all(root, "same bytes under allowed name")
            with self.assertRaisesRegex(MODULE.HistorySecretAuditError, "credential-bearing filename"):
                MODULE.audit(root)

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

    def test_large_blob_and_chunk_boundary_secrets_are_not_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            marker = ("gh" + "p_" + "x" * 30).encode()
            # Beyond the old 4MiB skip, with the token split across a chunk.
            padding = b" " * (5 * MODULE.SCAN_CHUNK_BYTES - 7)
            (root / "large.txt").write_bytes(padding + marker + b"\n")
            self.commit_all(root, "large synthetic leak")
            with self.assertRaises(MODULE.HistorySecretAuditError) as context:
                MODULE.audit(root)
            self.assertIn("GitHub token", str(context.exception))
            self.assertNotIn(marker.decode(), str(context.exception))


if __name__ == "__main__":
    unittest.main()
