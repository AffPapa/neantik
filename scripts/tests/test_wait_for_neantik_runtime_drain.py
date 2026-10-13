from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
import subprocess
import os
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "wait-for-neantik-runtime-drain.py"
SPEC = spec_from_file_location("wait_for_neantik_runtime_drain", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimeDrainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "NeAntik.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (
            self.app
            / "Contents"
            / "Resources"
            / "NeAntik Browser.app"
        ).mkdir(parents=True)

    def test_matches_only_exact_candidate_and_current_uid(self) -> None:
        manager = self.app / "Contents" / "MacOS" / "NeAntik"
        helper = (
            self.app
            / "Contents"
            / "Resources"
            / "NeAntik Browser.app"
            / "Contents"
            / "Frameworks"
            / "NeAntik Browser Helper"
        )
        table = "\n".join(
            [
                f"501 10 {manager}",
                f"501 11 {helper} --type=renderer --secret=hidden",
                f"501 12 /Applications/NeAntik.app/Contents/MacOS/NeAntik",
                f"501 13 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                f"502 14 {manager}",
            ]
        )

        self.assertEqual(
            MODULE.candidate_process_count(self.app, table, 501),
            2,
        )

    def test_path_with_spaces_is_matched_literally(self) -> None:
        manager = self.app / "Contents" / "MacOS" / "NeAntik"
        table = f"501 10 {manager} --neantik-release-fingerprint-audit"

        self.assertEqual(
            MODULE.candidate_process_count(self.app, table, 501),
            1,
        )

    def test_process_inventory_requests_untruncated_command_lines(self) -> None:
        completed = mock.Mock(returncode=0, stdout="")
        with mock.patch.object(
            MODULE.subprocess,
            "run",
            return_value=completed,
        ) as run:
            self.assertEqual(MODULE.read_process_table(), "")

        run.assert_called_once_with(
            ["/bin/ps", "-axww", "-o", "uid=,pid=,command="],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_unavailable_inventory_never_means_drained(self) -> None:
        with mock.patch.object(MODULE, "read_process_table", side_effect=RuntimeError("unavailable")):
            self.assertFalse(MODULE.wait_for_drain(self.app, 0.03, 0.01, 2))

    def test_live_owned_candidate_refuses_then_accepts_after_exit(self) -> None:
        # Actual native process, not a fabricated inventory. No browser or
        # user profile is involved; the process is a short owned fixture.
        executable = self.app / "Contents" / "MacOS" / "NeAntik"
        executable.symlink_to("/bin/sleep")
        child = subprocess.Popen([str(executable), "30"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.assertIsNone(child.poll())
            self.assertGreater(MODULE.candidate_process_count(self.app, MODULE.read_process_table(), os.getuid()), 0)
            blocked = subprocess.run(["python3", str(SCRIPT), "--app", str(self.app), "--timeout", "0.2", "--poll-interval", "0.03"], capture_output=True, text=True, timeout=5)
            self.assertEqual(blocked.returncode, 67)
            self.assertNotIn("PASS", blocked.stdout)
        finally:
            child.terminate()
            child.wait(timeout=5)
        accepted = subprocess.run(["python3", str(SCRIPT), "--app", str(self.app), "--timeout", "1", "--poll-interval", "0.03"], capture_output=True, text=True, timeout=5)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_release_guards_precede_bundle_mutations(self) -> None:
        for script, mutation, target in (
            (ROOT / "Release-NeAntik.command", 'mv "$artifact"', '$CANDIDATE_APP'),
            (ROOT / "scripts/Run-NeAntik-Release.command", 'mv "$APP_PATH"', '$APP_PATH'),
            (ROOT / "scripts/prepare-direct-manager-update.sh", 'rm -rf "$CANDIDATE_APP"', '$CANDIDATE_APP'),
        ):
            source = script.read_text()
            guard = source.index('"$PROJECT_DIR/scripts/wait-for-neantik-runtime-drain.py"')
            self.assertLess(guard, source.index(mutation))
            self.assertIn('--app "' + target + '" --timeout 2', source[guard:guard + 200])


if __name__ == "__main__":
    unittest.main()
