import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'prepare-chromium-15680-signing-package.py'
SPEC = importlib.util.spec_from_file_location('signing_package_15680', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IsolatedSigningPackageTests(unittest.TestCase):
    def test_copy_generation_and_changed_input_refusal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, out = root / 'src', root / 'out'
            source.mkdir(); out.mkdir()
            entitlements = source / 'chrome/app/app-entitlements.plist'
            entitlements.parent.mkdir(parents=True)
            entitlements.write_bytes(b'synthetic application entitlements')
            (out / 'toolchain.ninja').write_bytes(b'graph')
            config = out / 'NeAntik Browser Packaging/signing/build_props_config.py'
            config.parent.mkdir(parents=True)
            config.write_bytes(b"return '156.0.8078.74'\n")
            old = config.read_bytes()
            new = b"return '156.0.8078.80'\n"
            digest = lambda b: hashlib.sha256(b).hexdigest()
            spec = {'schemaVersion': 1, 'chromiumVersion': '156.0.8078.80',
                    'toolchainNinjaSHA256': digest(b'graph'), 'generatorInputs': {},
                    'files': {'signing/build_props_config.py': {'sha256': digest(old), 'mode': 0o644}},
                    'supplementalInputs': {'app-entitlements.plist': {
                        'source': 'chrome/app/app-entitlements.plist',
                        'sha256': digest(entitlements.read_bytes()), 'mode': 0o644}},
                    'generatedConfigSHA256': digest(new)}
            def generate(command, **kwargs):
                Path(command[command.index('-o') + 1]).write_bytes(new)
            with patch.object(MODULE.subprocess, 'run', side_effect=generate):
                dest = root / 'copy'
                MODULE.prepare(source, out, dest, spec)
                self.assertEqual((dest / 'signing/build_props_config.py').read_bytes(), new)
                self.assertEqual(config.read_bytes(), old)
                self.assertEqual((dest / 'app-entitlements.plist').read_bytes(), entitlements.read_bytes())
                saved_entitlements = entitlements.read_bytes()
                entitlements.write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, 'supplemental input changed'):
                    MODULE.prepare(source, out, root / 'wrong-entitlements', spec)
                self.assertFalse((root / 'wrong-entitlements').exists())
                entitlements.write_bytes(saved_entitlements)
                config.write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, 'differs from pinned inputs'):
                    MODULE.prepare(source, out, root / 'refused', spec)
                self.assertFalse((root / 'refused').exists())

    def test_changed_graph_refuses_before_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'src'; out = root / 'out'
            source.mkdir(); out.mkdir(); (out / 'toolchain.ninja').write_bytes(b'changed')
            spec = {'schemaVersion': 1, 'chromiumVersion': '156.0.8078.80',
                    'toolchainNinjaSHA256': '0' * 64}
            with self.assertRaisesRegex(ValueError, 'graph changed'):
                MODULE.prepare(source, out, root / 'refused', spec)
            self.assertFalse((root / 'refused').exists())
