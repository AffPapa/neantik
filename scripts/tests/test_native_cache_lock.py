import importlib.util
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "native_cache_lock.py"
SPEC = importlib.util.spec_from_file_location("native_lock", SCRIPT)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class NativeCacheLockTests(unittest.TestCase):
    def test_second_owner_cannot_start_child_and_unrelated_cache_can(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "cache"
            with MOD.cache_lock(root):
                result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--root", str(root), "--", sys.executable, "-c", "print('child started')"], capture_output=True, text=True)
                self.assertEqual(result.returncode, 75)
                self.assertNotIn("child started", result.stdout)
                with MOD.cache_lock(Path(directory) / "other"): pass
            with MOD.cache_lock(root): pass

    def test_inherited_descriptor_survives_shell_reentry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = 'exec "$1" -B "$2" --root "$3" --is-held'
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--root", str(root), "--", "/bin/zsh", "-c", code, "qa", sys.executable, str(SCRIPT), str(root)], capture_output=True)
            self.assertEqual(result.returncode, 0)

    def test_fake_descriptor_is_not_an_inherited_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            env = os.environ.copy(); env[MOD.ENV] = json.dumps({"root": directory, "fd": 987654})
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--root", directory, "--is-held"], env=env)
            self.assertEqual(result.returncode, 1)

    def test_independent_real_descriptor_cannot_bypass_competing_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with MOD.cache_lock(root):
                other = os.open(root / ".native-build.lock", os.O_RDONLY)
                try:
                    env = os.environ.copy(); env[MOD.ENV] = json.dumps({"root": str(root), "fd": other})
                    result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--root", str(root), "--", sys.executable, "-c", "print('wrong owner')"], env=env, pass_fds=(other,), capture_output=True)
                    self.assertEqual(result.returncode, 75)
                    self.assertNotIn(b"wrong owner", result.stdout)
                finally: os.close(other)

    def test_term_to_wrapper_cancels_own_child_and_does_not_run_later_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); ready = root / "ready"; late = root / "should-not-exist"
            child = "import pathlib,time;pathlib.Path(" + repr(str(ready)) + ").write_text('ready');time.sleep(2);pathlib.Path(" + repr(str(late)) + ").write_text('wrong')"
            process = subprocess.Popen([sys.executable, "-B", str(SCRIPT), "--root", str(root), "--", sys.executable, "-c", child], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 3
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline: time.sleep(.02)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(8), 143)
                self.assertFalse(late.exists())
                with MOD.cache_lock(root): pass
            finally:
                if process.poll() is None: process.kill(); process.wait()

    def test_symlink_lock_is_refused_without_modifying_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); target = root / "target"; target.write_text("kept")
            (root / ".native-build.lock").symlink_to(target)
            with self.assertRaises(OSError):
                with MOD.cache_lock(root): pass
            self.assertEqual(target.read_text(), "kept")
