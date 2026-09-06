import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "scripts" / "package-integrated-app.sh"
HELPER = ROOT / "scripts" / "verify-public-named-bundle.py"
INTEGRATED_VERIFIER = ROOT / "scripts" / "verify-integrated-release.sh"


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

    def test_packager_uses_explicit_engineering_verification(self) -> None:
        text = PACKAGER.read_text(encoding="utf-8")
        self.assertIn('verify-integrated-release.sh" --engineering "$OUTPUT_APP"', text)
        self.assertNotIn("verify-public-named-bundle.py", text)

    @unittest.skipUnless(shutil.which("zsh") and sys.platform == "darwin", "macOS shell gate")
    def test_manager_gate_has_explicit_non_inherited_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copytree(ROOT / "Resources", root / "Resources")
            shutil.copy2(HELPER, scripts / HELPER.name)
            # Execute the real dispatcher through the manager gate only.
            # Sentinel exit codes stop before expensive runtime verification.
            gate = scripts / INTEGRATED_VERIFIER.name
            text = INTEGRATED_VERIFIER.read_text(encoding="utf-8")
            gate.write_text(text.split('if [[ ! -d "$RUNTIME_APP" ]]')[0])
            gate.chmod(0o755)
            manager_gate = scripts / "verify-release.sh"
            manager_gate.write_text(
                '#!/bin/sh\nset -eu\n'
                'test "$(basename "$1")" = "NeAntik.app" || exit 99\n'
                'if [ "$NEANTIK_LOCAL_ADHOC" = 0 ]; then exit 71; fi\n'
                'test "$NEANTIK_LOCAL_ADHOC" = 1 || exit 98\nexit 72\n'
            )
            manager_gate.chmod(0o755)
            env = dict(os.environ, NEANTIK_LOCAL_ADHOC="1")
            for name, flags, expected in (
                ("NeAntik.app", [], 71),
                ("NeAntik-Integrated.app", ["--engineering"], 72),
                ("NeAntik.app", ["--engineering"], 64),
                ("Other.app", ["--engineering"], 64),
            ):
                with self.subTest(name=name, flags=flags):
                    app = root / name
                    if not app.exists():
                        (app / "Contents").mkdir(parents=True)
                        shutil.copy2(ROOT / "Resources/Info.plist", app / "Contents/Info.plist")
                        shutil.copytree(ROOT / "Resources/ru.lproj", app / "Contents/Resources/ru.lproj")
                    before = directory_digest(app)
                    result = subprocess.run(
                        [str(gate), *flags, str(app)], env=env,
                        capture_output=True, text=True, timeout=15, check=False,
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(directory_digest(app), before)

    def test_engineering_and_public_share_runtime_gates(self) -> None:
        text = INTEGRATED_VERIFIER.read_text(encoding="utf-8")
        common = text.split('if [[ ! -d "$RUNTIME_APP" ]]')[1]
        for required in (
            "audit-app-size.py", "verify-built-runtime.sh",
            "verify-packaged-runtime-report.py", "verify-runtime-compliance.sh",
            "verify-runtime-source-provenance.py", "verify-runtime-candidate-lock.py",
            "codesign --verify --deep --strict",
        ):
            self.assertIn(required, common)
        before_summary = common.split("if (( ENGINEERING )); then")[0]
        self.assertNotIn("ENGINEERING", before_summary)

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
