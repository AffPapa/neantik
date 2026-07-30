import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "run-exact-command-with-timeout.py"
)
SPEC = importlib.util.spec_from_file_location(
    "run_exact_command_with_timeout",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ExactCommandTimeoutTests(unittest.TestCase):
    def test_preserves_exit_status_and_does_not_invoke_shell(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "5",
                "--",
                "/bin/sh",
                "-c",
                "exit \"$1\"",
                "sh",
                "37",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 37)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "")

    def test_argument_metacharacters_are_passed_literally(self) -> None:
        marker = "literal; touch /private/tmp/must-not-run"
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "5",
                "--",
                "/usr/bin/printf",
                "%s",
                marker,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, marker)

    def test_timeout_terminates_only_the_owned_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pid_file = root / "pid"
            child = root / "child.sh"
            child.write_text(
                "#!/bin/sh\n"
                "printf '%s' \"$$\" >\"$1\"\n"
                "exec /bin/sleep 30\n",
                encoding="utf-8",
            )
            child.chmod(0o700)
            started = time.monotonic()
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--timeout",
                    "1",
                    "--",
                    str(child),
                    str(pid_file),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            elapsed = time.monotonic() - started
            pid = int(pid_file.read_text(encoding="utf-8"))

        self.assertEqual(completed.returncode, 124)
        self.assertLess(elapsed, 6)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_private_log_is_created_once_without_stdout_reopen(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "command.log"
            command = [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "5",
                "--log",
                str(log),
                "--",
                "/usr/bin/printf",
                "%s",
                "private child output",
            ]
            first = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
            )
            initial = log.read_bytes()
            mode = log.stat().st_mode & 0o777
            second = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
            )
            final = log.read_bytes()

        self.assertEqual(first.returncode, 0)
        self.assertEqual(first.stdout, "")
        self.assertEqual(first.stderr, "")
        self.assertEqual(final, b"private child output")
        self.assertEqual(mode, 0o600)
        self.assertEqual(second.returncode, 64)
        self.assertEqual(initial, b"private child output")

    def test_rejects_relative_missing_and_symlink_executables(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            symlink = root / "shell"
            symlink.symlink_to("/bin/sh")
            for executable in (
                "relative",
                str(root / "missing"),
                str(symlink),
            ):
                completed = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "--timeout",
                        "1",
                        "--",
                        executable,
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                with self.subTest(executable=executable):
                    self.assertEqual(completed.returncode, 64)
                    self.assertNotIn(executable, completed.stderr)


if __name__ == "__main__":
    unittest.main()
