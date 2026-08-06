import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "scripts" / "package-integrated-app.sh"
HELPER = ROOT / "scripts" / "verify-public-named-bundle.py"


def directory_digest(path: Path) -> str:
    digest = hashlib.sha256()
    for child in sorted(path.rglob("*")):
        digest.update(str(child.relative_to(path)).encode())
        if child.is_file():
            digest.update(child.read_bytes())
    return digest.hexdigest()


class PackageIntegratedAppScriptTests(unittest.TestCase):
    def make_verifier(self, root: Path, body: str) -> Path:
        verifier = root / "verifier.sh"
        verifier.write_text(
            "#!/bin/sh\nset -eu\n" + body + "\n",
            encoding="utf-8",
        )
        verifier.chmod(0o755)
        return verifier

    def run_helper(
        self,
        engineering_app: Path,
        verifier: Path,
        *,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--engineering-app",
                str(engineering_app),
                "--verifier",
                str(verifier),
            ],
            text=True,
            capture_output=True,
            env=env,
            timeout=10,
            check=False,
        )

    def test_packager_uses_atomic_public_name_helper(self) -> None:
        text = PACKAGER.read_text(encoding="utf-8")

        self.assertIn("verify-public-named-bundle.py", text)
        self.assertIn('--engineering-app "$OUTPUT_APP"', text)
        self.assertIn("verify-integrated-release.sh", text)
        self.assertNotIn(
            'verify-integrated-release.sh" "$OUTPUT_APP"',
            text,
        )

    def test_failing_verifier_restores_exact_engineering_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engineering_app = root / "NeAntik-Integrated.app"
            engineering_app.mkdir()
            (engineering_app / "marker").write_bytes(b"exact bundle")
            before = directory_digest(engineering_app)
            verifier = self.make_verifier(
                root,
                'test "$(basename "$1")" = "NeAntik.app"\nexit 73',
            )

            result = self.run_helper(engineering_app, verifier)

            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertEqual(directory_digest(engineering_app), before)
            self.assertFalse(
                list(root.glob(".neantik-public-name-verification.*"))
            )

    def test_signal_restores_exact_engineering_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engineering_app = root / "NeAntik-Integrated.app"
            engineering_app.mkdir()
            (engineering_app / "marker").write_bytes(b"signal-safe")
            before = directory_digest(engineering_app)
            verifier = self.make_verifier(
                root,
                'kill -TERM "$PPID"\nsleep 5',
            )

            result = self.run_helper(engineering_app, verifier)

            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual(directory_digest(engineering_app), before)
            self.assertFalse(
                list(root.glob(".neantik-public-name-verification.*"))
            )

    def test_restore_conflict_preserves_verified_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engineering_app = root / "NeAntik-Integrated.app"
            engineering_app.mkdir()
            (engineering_app / "marker").write_bytes(b"preserve me")
            verifier = self.make_verifier(
                root,
                'mkdir "$ORIGINAL_APP"\nexit 74',
            )
            env = dict(os.environ)
            env["ORIGINAL_APP"] = str(engineering_app)

            result = self.run_helper(engineering_app, verifier, env=env)

            self.assertEqual(result.returncode, 70, result.stderr)
            preserved = list(
                root.glob(
                    ".neantik-public-name-verification.*/NeAntik.app/marker"
                )
            )
            self.assertEqual(len(preserved), 1)
            self.assertEqual(preserved[0].read_bytes(), b"preserve me")
            self.assertIn("preserved at", result.stderr)

    def test_symlink_bundle_is_rejected_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.app"
            target.mkdir()
            (target / "marker").write_bytes(b"untouched")
            engineering_app = root / "NeAntik-Integrated.app"
            engineering_app.symlink_to(target)
            verifier = self.make_verifier(root, "exit 0")

            result = self.run_helper(engineering_app, verifier)

            self.assertEqual(result.returncode, 70, result.stderr)
            self.assertTrue(engineering_app.is_symlink())
            self.assertEqual((target / "marker").read_bytes(), b"untouched")


if __name__ == "__main__":
    unittest.main()
