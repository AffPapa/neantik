import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("python_regression", SCRIPTS / "run-python-regression.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class PythonRegressionRunnerTests(unittest.TestCase):
    def test_missing_capability_blocks_before_starting_suite(self):
        output = io.StringIO()
        with mock.patch.object(MOD, "full_run_capability_gaps", return_value=["loopback-udp"]), \
                mock.patch.object(MOD.subprocess, "run") as run_suite, \
                contextlib.redirect_stdout(output):
            self.assertEqual(MOD.main(), 75)
        receipt = json.loads(output.getvalue())
        self.assertEqual(receipt["status"], "blocked")
        self.assertEqual(receipt["missingCapabilities"], ["loopback-udp"])
        self.assertFalse(receipt["testsStarted"])
        self.assertFalse(receipt["releaseGate"])
        run_suite.assert_not_called()

    def test_available_capabilities_run_full_python_suite(self):
        with mock.patch.object(MOD, "full_run_capability_gaps", return_value=[]), \
                mock.patch.object(MOD.subprocess, "run", return_value=mock.Mock(returncode=0)) as run_suite:
            self.assertEqual(MOD.main(), 0)
        args, kwargs = run_suite.call_args
        self.assertIn("unittest", args[0])
        self.assertEqual(args[0][-1], "test_*.py")
        self.assertEqual(kwargs["cwd"], MOD.ROOT)
        self.assertEqual(kwargs["env"]["PYTHONDONTWRITEBYTECODE"], "1")


if __name__ == "__main__":
    unittest.main()
