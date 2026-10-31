import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import importlib.util

module_path = Path(__file__).resolve().parents[1] / "verify-chromium-15648-source-adoption.py"
_spec = importlib.util.spec_from_file_location("chromium_15648_source_adoption", module_path)
verify_module = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = verify_module
_spec.loader.exec_module(verify_module)


class DependencyLockTests(unittest.TestCase):
    def test_manifest_dispatch_includes_m15674_without_changing_m15648_default(self):
        self.assertEqual(verify_module.SUPPORTED_MANIFESTS[
            "chromium-15648-source-adoption-v3.json"], "156.0.8078.48")
        self.assertEqual(verify_module.SUPPORTED_MANIFESTS[
            "chromium-15674-source-adoption-v1.json"], "156.0.8078.74")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "src"
        self.source.mkdir()
        self.entries_file = self.root / ".gclient_entries"
        self.entries_file.write_text("pinned entries\n")
        self.entries_sha = hashlib.sha256(self.entries_file.read_bytes()).hexdigest()

    def git_checkout(self, relative):
        path = self.root / relative
        path.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        (path / "pin.txt").write_text(relative + "\n")
        subprocess.run(["git", "-C", str(path), "add", "pin.txt"], check=True)
        env = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
               "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        subprocess.run(["git", "-C", str(path), "commit", "-q", "-m", "pin"], check=True, env=env)
        commit = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
        tree = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD^{tree}"], text=True).strip()
        return {"commit": commit, "tree": tree}

    def test_checks_every_checkout_and_gclient_entries_hash(self):
        entries = {
            "src/third_party/one": self.git_checkout("src/third_party/one"),
            "src/third_party/two": self.git_checkout("src/third_party/two"),
        }
        self.assertEqual(2, verify_module.verify_dependency_checkouts(self.source, entries, self.entries_sha))

    def test_rejects_mismatched_commit(self):
        pin = self.git_checkout("src/third_party/one")
        pin["commit"] = "0" * 40
        with self.assertRaisesRegex(verify_module.AdoptionError, "dependency commit mismatch"):
            verify_module.verify_dependency_checkouts(
                self.source, {"src/third_party/one": pin}, self.entries_sha
            )

    def test_rejects_mismatched_gclient_entries(self):
        with self.assertRaisesRegex(verify_module.AdoptionError, "\.gclient_entries digest mismatch"):
            verify_module.verify_dependency_checkouts(self.source, {}, "0" * 64)

    def test_rejects_unsafe_checkout_path(self):
        with self.assertRaisesRegex(verify_module.AdoptionError, "unsafe dependency checkout path"):
            verify_module.verify_dependency_checkouts(
                self.source, {"src/../outside": {"commit": "0" * 40, "tree": "0" * 40}}, self.entries_sha
            )


if __name__ == "__main__":
    unittest.main()
