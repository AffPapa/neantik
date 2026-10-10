"""Controls for the owned deferred launch, never for a browser PASS."""
import hashlib
import importlib.util
import json
import marshal
import os
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

LAUNCH = (Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major/verify-postbuild-full-source-attempt-4.py')
NAMES = ('chromium_15612_receipt_projection.py', 'chromium_15612_generated_cache.py',
         'chromium_15612_postbuild.py', 'chromium_15612_live_source.py')


class M156DeferredLaunchTests(unittest.TestCase):
    def launcher(self):
        if not LAUNCH.is_file(): self.skipTest('Owned private deferred launcher is not present')
        module = types.ModuleType('owned_deferred_source_launch')
        module.__file__ = str(LAUNCH)
        exec(compile(LAUNCH.read_bytes(), str(LAUNCH), 'exec'), module.__dict__)
        return module

    def own_sources(self, root):
        for name in NAMES:
            (root / name).write_text('VALUE = "authenticated-source"\n')
        return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in NAMES}

    def restore_modules(self, existing):
        for name in NAMES:
            key = name[:-3]
            if key in existing: sys.modules[key] = existing[key]
            else: sys.modules.pop(key, None)

    def test_matching_header_pyc_is_detected_by_broken_control_and_ignored_by_source_loader(self):
        launcher = self.launcher()
        existing = dict(sys.modules)
        with tempfile.TemporaryDirectory(prefix='neantik-pyc-execution-control-') as temp:
            root = Path(temp).resolve(); pins = self.own_sources(root)
            source = root / 'chromium_15612_live_source.py'
            info = source.stat()
            # Intentional broken control: timestamp-valid pyc with different code.
            malicious = compile('raise RuntimeError("OWNED_PYC_SENTINEL")', str(source), 'exec')
            pyc = Path(importlib.util.cache_from_source(str(source))); pyc.parent.mkdir()
            pyc.write_bytes(importlib.util.MAGIC_NUMBER + struct.pack('<III', 0, int(info.st_mtime), info.st_size)
                            + marshal.dumps(malicious))
            probe = subprocess.run([sys.executable, '-B', '-S', '-c',
                                    'import sys;sys.path.insert(0,sys.argv[1]);import chromium_15612_live_source',
                                    str(root)], capture_output=True, text=True, timeout=15)
            self.assertNotEqual(probe.returncode, 0)
            self.assertIn('OWNED_PYC_SENTINEL', probe.stderr)
            try:
                loaded = launcher.load_reviewed_sources(root, pins)
                self.assertEqual(len(loaded), 4)
                for module in loaded.values(): self.assertEqual(module.VALUE, 'authenticated-source')
            finally:
                self.restore_modules(existing)

    def test_source_hash_mismatch_refused_before_any_module_execution(self):
        launcher = self.launcher(); existing = dict(sys.modules)
        with tempfile.TemporaryDirectory(prefix='neantik-authenticated-source-pins-') as temp:
            root = Path(temp).resolve(); pins = self.own_sources(root)
            # A wrong digest is not fixed by loading a source with the same name.
            pins[NAMES[-1]] = 'b' * 64
            with self.assertRaisesRegex(ValueError, 'before load'):
                launcher.load_reviewed_sources(root, pins)
            for name in NAMES:
                self.assertIs(sys.modules.get(name[:-3]), existing.get(name[:-3]))
            with self.assertRaisesRegex(ValueError, 'module set'):
                launcher.load_reviewed_sources(root, {})

    def test_actual_deferred_launch_refuses_running_build_without_inventory_outputs(self):
        self.launcher()
        artifacts = LAUNCH.parent
        state = json.loads((artifacts / 'm156-native-build-attempt-4-state.json').read_bytes())
        if state.get('status') != 'single-native-build-running': self.skipTest('Native build no longer running')
        config = json.loads((artifacts / 'postbuild-full-source-observation-launch-v2.json').read_bytes())
        names = ('fullName', 'compactName', 'producerReceiptName', 'observationName')
        for key in names: self.assertFalse((artifacts / config[key]).exists())
        result = subprocess.run(['/opt/homebrew/bin/python3.14', '-B', '-S', str(LAUNCH)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, '')
        self.assertEqual(json.loads(result.stdout), {'status': 'refused', 'exceptionType': 'M156CacheError',
                                                     'runtimeQualified': False, 'releaseReady': False})
        for key in names: self.assertFalse((artifacts / config[key]).exists())


if __name__ == '__main__': unittest.main()
