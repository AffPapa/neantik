"""CI entrypoint for the owned JS speech oracle; never launches a browser."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which('node')


@unittest.skipUnless(NODE, 'Node is required for speech oracle controls')
class RuntimeSpeechTests(unittest.TestCase):
    def test_probe_oracle_and_scoped_transport_controls(self):
        result = subprocess.run([NODE, '--test',
            'scripts/runtime-speech/test-observation.mjs',
            'scripts/runtime-speech/test-pipe.mjs',
            'scripts/runtime-speech/test-cleanup.mjs'], cwd=ROOT,
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('# tests 14', result.stdout)
        self.assertIn('# fail 0', result.stdout)

    def test_headed_controller_has_valid_syntax_without_execution(self):
        result = subprocess.run([NODE, '--check', 'scripts/runtime-speech/run-headed.mjs'],
            cwd=ROOT, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
