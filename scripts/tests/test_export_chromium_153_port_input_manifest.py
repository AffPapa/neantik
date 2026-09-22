from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / (
    "export-chromium-153-port-input-manifest.py"
)
SPEC = importlib.util.spec_from_file_location("chromium_153_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Chromium153PortInputManifestTests(unittest.TestCase):
    def make_repo(self, root: Path) -> None:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "add", "tracked.txt"],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            check=True,
        )

    def test_exports_deterministic_untracked_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            self.make_repo(root)
            (root / "generated.txt").write_text("generated\n", encoding="utf-8")

            first = MODULE.build_manifest(root, ())
            second = MODULE.build_manifest(root, ())

            self.assertEqual(first, second)
            self.assertEqual(first["untrackedFileCount"], 1)
            self.assertEqual(first["untrackedInputs"][0]["path"], "generated.txt")
            self.assertEqual(first["binaryBindingStatus"], "pending-new-build")

    def test_rejects_patch_rejection_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            self.make_repo(root)
            (root / "failed.patch.rej").write_text("reject\n", encoding="utf-8")

            with self.assertRaisesRegex(MODULE.ManifestError, "rejection artifact"):
                MODULE.build_manifest(root, ())


if __name__ == "__main__":
    unittest.main()
