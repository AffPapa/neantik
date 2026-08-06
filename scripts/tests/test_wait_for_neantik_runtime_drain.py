from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
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


if __name__ == "__main__":
    unittest.main()
