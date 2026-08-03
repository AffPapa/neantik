import plistlib
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "scripts" / "Run-NeAntik-Runtime-Audit.command"


class RuntimeAuditLauncherTests(unittest.TestCase):
    def make_package(self, root: Path, *, auditor_body: str) -> Path:
        launcher = root / LAUNCHER.name
        launcher.write_bytes(LAUNCHER.read_bytes())
        launcher.chmod(0o755)

        app = root / "NeAntik Browser.app"
        executable = app / "Contents" / "MacOS" / "NeAntik Browser"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        with (app / "Contents" / "Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleExecutable": "NeAntik Browser"}, file)

        auditor = root / "NeAntikRuntimeAudit"
        auditor.write_text(auditor_body, encoding="utf-8")
        auditor.chmod(0o755)

        verifier = root / "verify-gui-fingerprint-report.py"
        verifier.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import pathlib
                import sys
                pathlib.Path(__file__).with_name("verifier-args.txt").write_text(
                    "\\n".join(sys.argv[1:]),
                    encoding="utf-8",
                )
                raise SystemExit(0)
                """
            ),
            encoding="utf-8",
        )
        (root / "evidence").mkdir()
        (root / "evidence" / "fingerprint-chromium.lock.json").write_text(
            "{}\n",
            encoding="utf-8",
        )
        return launcher

    def test_launcher_is_executable_and_shell_syntax_is_valid(self) -> None:
        self.assertTrue(LAUNCHER.stat().st_mode & stat.S_IXUSR)
        result = subprocess.run(
            ["bash", "-n", str(LAUNCHER)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_success_runs_independent_verifier_with_pinned_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launcher = self.make_package(
                root,
                auditor_body=(
                    "#!/bin/sh\n"
                    "printf '%s\\n' '{\"schemaVersion\":5}' > \"$2\"\n"
                    "exit 0\n"
                ),
            )
            result = subprocess.run(
                [str(launcher)],
                text=True,
                capture_output=True,
                check=False,
            )
            verifier_args = (root / "verifier-args.txt").read_text(encoding="utf-8")
            log = (root / "fingerprint-audit-terminal.log").read_text(
                encoding="utf-8"
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fingerprint-audit.json", verifier_args)
        self.assertIn("--runtime-lock", verifier_args)
        self.assertIn("--require-production", verifier_args)
        self.assertIn("fingerprint-chromium.lock.json", verifier_args)
        self.assertIn("Independent production GUI report verification", log)
        self.assertIn("production-qualified A -> B -> A report", result.stdout)

    def test_failed_new_audit_removes_stale_report_and_skips_verifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launcher = self.make_package(
                root,
                auditor_body="#!/bin/sh\nexit 7\n",
            )
            report = root / "fingerprint-audit.json"
            report.write_text('{"stale":true}\n', encoding="utf-8")

            result = subprocess.run(
                [str(launcher)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 7)
            self.assertFalse(report.exists())
            self.assertFalse((root / "verifier-args.txt").exists())
            self.assertIn(
                "independent verification was not run",
                (root / "fingerprint-audit-terminal.log").read_text(
                    encoding="utf-8"
                ),
            )

    def test_launcher_does_not_fall_back_to_unbranded_chromium(self) -> None:
        text = LAUNCHER.read_text(encoding="utf-8")
        self.assertNotIn("Chromium.app", text)
        self.assertIn("umask 077", text)
        self.assertIn('rm -f "$REPORT" "$LOG"', text)


if __name__ == "__main__":
    unittest.main()
