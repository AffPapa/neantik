import os
import py_compile
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


RUNNER = (
    Path(__file__).resolve().parents[1]
    / "run-isolated-release-python.py"
)


class IsolatedReleasePythonTests(unittest.TestCase):
    def test_runner_requires_isolated_no_bytecode_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "dist").mkdir(mode=0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            target = scripts / "release_entry.py"
            target.write_text("print('UNREACHABLE')\n", encoding="utf-8")

            completed = subprocess.run(
                [sys.executable, str(RUNNER), str(target)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 65)
            self.assertIn("requires Python -I -B", completed.stderr)

    def test_ignored_timestamp_pyc_is_not_imported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "dist").mkdir(mode=0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            target = scripts / "release_entry.py"
            target.write_text(
                "import release_helper\n"
                "print(release_helper.VALUE)\n",
                encoding="utf-8",
            )
            helper = scripts / "release_helper.py"
            good = "VALUE = 'GOOD'\n"
            evil = "VALUE = 'EVIL'\n"
            self.assertEqual(len(good), len(evil))
            helper.write_text(evil, encoding="utf-8")
            timestamp = 1_700_000_000
            os.utime(helper, (timestamp, timestamp))
            py_compile.compile(helper, doraise=True)
            helper.write_text(good, encoding="utf-8")
            os.utime(helper, (timestamp, timestamp))

            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-B",
                    str(RUNNER),
                    str(target),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), "GOOD")

    def test_real_notary_module_graph_loads_under_runner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "dist").mkdir(mode=0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in (
                "notarize_direct_transaction.py",
                "notary_transaction_state.py",
                "release_input_snapshot.py",
                "release_source_receipt.py",
                "release_transaction.py",
            ):
                shutil.copy2(RUNNER.parent / name, scripts / name)
            target = scripts / "notarize_direct_transaction.py"
            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-B",
                    str(RUNNER),
                    str(target),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 2, completed.stderr)
            self.assertIn("--project-root", completed.stderr)

    def test_read_only_notary_inspector_runs_under_runner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "dist").mkdir(mode=0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(
                RUNNER.parent / "notary_transaction_inspector.py",
                scripts / "notary_transaction_inspector.py",
            )
            target = scripts / "notary_transaction_inspector.py"
            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-B",
                    str(RUNNER),
                    str(target),
                    "--project-root",
                    str(root),
                    "--release-gate",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(
                "локальных транзакций выпуска нет",
                completed.stdout,
            )
            self.assertFalse((scripts / "__pycache__").exists())

    def test_child_python_cannot_write_repository_bytecode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "dist").mkdir(mode=0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "release_child_helper.py").write_text(
                "VALUE = 'CHILD-GOOD'\n",
                encoding="utf-8",
            )
            (scripts / "release_child.py").write_text(
                "import release_child_helper\n"
                "print(release_child_helper.VALUE)\n",
                encoding="utf-8",
            )
            target = scripts / "release_entry.py"
            target.write_text(
                "import subprocess,sys\n"
                "raise SystemExit(subprocess.run("
                "[sys.executable, 'release_child.py'], "
                "check=False).returncode)\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-B",
                    str(RUNNER),
                    str(target),
                ],
                cwd=scripts,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("CHILD-GOOD", completed.stdout)
            self.assertFalse((scripts / "__pycache__").exists())

    def test_nested_project_inside_parent_git_worktree_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            subprocess.run(
                ["git", "init"],
                cwd=parent,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
            )
            root = parent / "nevision"
            root.mkdir()
            (root / "dist").mkdir(mode=0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            target = scripts / "release_entry.py"
            target.write_text("print('NESTED-OK')\n", encoding="utf-8")

            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-B",
                    str(RUNNER),
                    str(target),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), "NESTED-OK")

    def test_scripts_root_cannot_shadow_standard_library(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "dist").mkdir(mode=0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "fractions.py").write_text(
                "raise RuntimeError('shadowed stdlib')\n",
                encoding="utf-8",
            )
            target = scripts / "release_entry.py"
            target.write_text(
                "from fractions import Fraction\n"
                "print(Fraction(1, 2))\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-B",
                    str(RUNNER),
                    str(target),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), "1/2")

    def test_git_worktree_check_uses_system_git(self) -> None:
        runner_text = RUNNER.read_text(encoding="utf-8")
        self.assertIn('SYSTEM_GIT = "/usr/bin/git"', runner_text)
        self.assertNotIn('[\n                "git",', runner_text)
