import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('runtime_build_path', Path(__file__).resolve().parents[1] / 'runtime_build_path.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class RuntimeBuildPathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.src = self.root / 'src'
        self.args = self.src / 'out/Qualified/args.gn'
        self.args.parent.mkdir(parents=True)
        self.args.write_text('angle_enable_metal = true\n')
        (self.root / 'runtime').mkdir()
        self.lock = {'fingerprintChromium': {'chromiumVersion': '154.0.8037.93'}}
        self.freeze('out/Qualified/args.gn')
    def freeze(self, relative):
        p = self.root / 'runtime/chromium-154-source-snapshot.json'
        p.write_text(json.dumps({'argsGN': {'relativePath': relative, 'sha256': hashlib.sha256(self.args.read_bytes()).hexdigest()}}))
        (p.parent / 'chromium-154-source-contract.json').write_text(json.dumps({'sourceSnapshotSHA256': hashlib.sha256(p.read_bytes()).hexdigest()}))
    def verify(self, path=None):
        return module.verify_build_args(self.src, path or self.args, self.lock, self.root)
    def test_recorded_custom_directory_passes(self):
        self.assertEqual(self.verify(), self.args.resolve())
    def test_copied_args_rejected(self):
        p = self.root / 'args.gn'; p.write_bytes(self.args.read_bytes())
        with self.assertRaises(ValueError): self.verify(p)
    def test_changed_bytes_rejected(self):
        self.args.write_text('changed')
        with self.assertRaises(ValueError): self.verify()
    def test_path_traversal_rejected(self):
        self.freeze('out/../args.gn')
        with self.assertRaises(ValueError): self.verify()
    def test_unbound_snapshot_rejected(self):
        (self.root / 'runtime/chromium-154-source-snapshot.json').write_text('{}')
        with self.assertRaises(ValueError): self.verify()
    def test_legacy_default_still_required(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '153.0.8010.52'
        with self.assertRaises(ValueError): self.verify()
        p = self.src / 'out/Default/args.gn'; p.parent.mkdir();p.write_bytes(self.args.read_bytes())
        self.assertEqual(self.verify(p),p.resolve())
