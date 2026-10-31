import hashlib
import sys
import importlib.util
import json
import tempfile
import types
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))

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
    def freeze(self, relative, prefix='chromium-154'):
        p = self.root / 'runtime' / f'{prefix}-source-snapshot.json'
        p.write_text(json.dumps({'argsGN': {'relativePath': relative, 'sha256': hashlib.sha256(self.args.read_bytes()).hexdigest()}}))
        (p.parent / f'{prefix}-source-contract.json').write_text(json.dumps({'sourceSnapshotSHA256': hashlib.sha256(p.read_bytes()).hexdigest()}))
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
    def test_15498_uses_separate_bound_snapshot(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '154.0.8037.98'
        with self.assertRaises(FileNotFoundError): self.verify()
        self.freeze('out/Qualified/args.gn', 'chromium-15498')
        self.assertEqual(self.verify(), self.args.resolve())
        self.args.write_text('changed')
        with self.assertRaises(ValueError): self.verify()
    def test_unknown_m154_rejected(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '154.0.8037.99'
        with self.assertRaisesRegex(ValueError, 'Unsupported Chromium build path version'):
            self.verify()

    def test_future_port_cannot_fall_back_to_legacy_default(self):
        p = self.src / 'out/Default/args.gn'
        p.parent.mkdir()
        p.write_bytes(self.args.read_bytes())
        for version in ['156.0.8078.13', '157.0.9000.1', '999.1.2.3']:
            with self.subTest(version=version):
                self.lock['fingerprintChromium']['chromiumVersion'] = version
                with self.assertRaisesRegex(ValueError, 'Unsupported Chromium build path version'):
                    self.verify(p)

    def test_supported_m156_still_rejects_legacy_default_before_evidence_read(self):
        self.lock['fingerprintChromium']['chromiumVersion']='156.0.8078.12'
        p=self.src/'out/Default/args.gn';p.parent.mkdir();p.write_bytes(self.args.read_bytes())
        with self.assertRaisesRegex(ValueError,'exact M156 qualified'):
            self.verify(p)

    def test_missing_or_malformed_version_cannot_use_legacy_path(self):
        p = self.src / 'out/Default/args.gn'
        p.parent.mkdir()
        p.write_bytes(self.args.read_bytes())
        for version in [None, '', '156', '156.0.8078', '156.0.8078.12.extra', '１５６.0.1.2', 'a.1.2.3']:
            with self.subTest(version=version):
                self.lock['fingerprintChromium']['chromiumVersion'] = version
                with self.assertRaisesRegex(ValueError, 'Invalid Chromium build path version'):
                    self.verify(p)

    def test_15540_requires_its_own_bound_snapshot(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '155.0.8059.40'
        self.lock['sourceContract']='runtime/chromium-15540-source-contract.json'
        with self.assertRaises(FileNotFoundError): self.verify()
        self.freeze('out/Qualified/args.gn', 'chromium-15540')
        self.assertEqual(self.verify(), self.args.resolve())
        self.args.write_text('changed')
        with self.assertRaises(ValueError): self.verify()

    def test_stripped_semantic_variant_cannot_use_base_path(self):
        self.lock.update(fingerprintChromium={'chromiumVersion':'155.0.8059.40'},sourceContract='runtime/chromium-15540-semantic-v3-source-contract.json')
        with self.assertRaisesRegex(ValueError,'variant mismatch'):self.verify()
    def test_unknown_semantic_variant_rejected(self):
        self.lock.update(fingerprintChromium={'chromiumVersion':'155.0.8059.40'},semanticCorrectionSet='optional')
        with self.assertRaisesRegex(ValueError,'Unknown additive'):self.verify()

    def test_m15674_uses_manifest_bound_build_directory(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '156.0.8078.74'
        adoption = self.root / 'runtime/chromium-15674-source-adoption-v1.json'
        adoption.write_text(json.dumps({'buildOutputDirectory': 'out/NeAntikStable156_48'}))
        args = self.src / 'out/NeAntikStable156_48/args.gn'
        args.parent.mkdir(parents=True)
        args.write_text('official build args\n')
        self.lock['ownedInputs'] = {'buildArgsSHA256': hashlib.sha256(args.read_bytes()).hexdigest()}
        helper = types.ModuleType('chromium_15674_release_evidence')
        helper.verify_contract = lambda project_root: {'buildArgsSHA256': hashlib.sha256(args.read_bytes()).hexdigest()}
        with patch.dict(sys.modules, {'chromium_15674_release_evidence': helper}):
            self.assertEqual(module.verify_build_args(self.src, args, self.lock, self.root), args.resolve())

    def test_m15674_rejects_unsafe_manifest_build_directory(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '156.0.8078.74'
        adoption = self.root / 'runtime/chromium-15674-source-adoption-v1.json'
        adoption.write_text(json.dumps({'buildOutputDirectory': 'out/../escape'}))
        helper = types.ModuleType('chromium_15674_release_evidence')
        helper.verify_contract = lambda project_root: {}
        with patch.dict(sys.modules, {'chromium_15674_release_evidence': helper}):
            with self.assertRaisesRegex(ValueError, 'output directory is invalid'):
                module.verify_build_args(self.src, self.args, self.lock, self.root)

    def test_m15680_uses_manifest_bound_build_directory(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '156.0.8078.80'
        adoption = self.root / 'runtime/chromium-15680-source-adoption-v1.json'
        adoption.write_text(json.dumps({'buildOutputDirectory': 'out/NeAntikStable156_48'}))
        args = self.src / 'out/NeAntikStable156_48/args.gn'
        args.parent.mkdir(parents=True)
        args.write_text('156.80 authenticated build args\n')
        expected_hash = hashlib.sha256(args.read_bytes()).hexdigest()
        helper = types.ModuleType('chromium_15680_release_evidence')
        helper.verify_contract = lambda project_root: {'buildArgsSHA256': expected_hash}
        with patch.dict(sys.modules, {'chromium_15680_release_evidence': helper}):
            self.assertEqual(module.verify_build_args(self.src, args, self.lock, self.root), args.resolve())
            stale = self.src / 'out/NeAntikStable156_48-stale/args.gn'
            stale.parent.mkdir(parents=True)
            stale.write_bytes(args.read_bytes())
            with self.assertRaisesRegex(ValueError, 'Expected exact M156.80 build args path'):
                module.verify_build_args(self.src, stale, self.lock, self.root)

    def test_m15680_rejects_unsafe_manifest_build_directory(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '156.0.8078.80'
        adoption = self.root / 'runtime/chromium-15680-source-adoption-v1.json'
        adoption.write_text(json.dumps({'buildOutputDirectory': 'out/../escape'}))
        helper = types.ModuleType('chromium_15680_release_evidence')
        helper.verify_contract = lambda project_root: {}
        with patch.dict(sys.modules, {'chromium_15680_release_evidence': helper}):
            with self.assertRaisesRegex(ValueError, 'output directory is invalid'):
                module.verify_build_args(self.src, self.args, self.lock, self.root)

    def test_m15680_derived_output_cannot_use_original_build_directory(self):
        self.lock['fingerprintChromium']['chromiumVersion'] = '156.0.8078.80'
        adoption = self.root / 'runtime/chromium-15680-source-adoption-v1.json'
        adoption.write_text(json.dumps({'buildOutputDirectory': 'out/NeAntikStable156_48'}))
        args = self.src / 'out/NeAntikStable156_80PortableCRC/args.gn'
        args.parent.mkdir(parents=True)
        args.write_text('derived build args\n')
        helper = types.ModuleType('chromium_15680_release_evidence')
        helper.verify_contract = lambda project_root: {
            'portableCRC': {'file': 'bound overlay'},
            'buildArgsSHA256': hashlib.sha256(args.read_bytes()).hexdigest()}
        with patch.dict(sys.modules, {'chromium_15680_release_evidence': helper}), \
                patch('chromium_15680_portable_crc.verify', return_value={
                    'candidateOutputDirectory': 'out/NeAntikStable156_80PortableCRC'}):
            self.assertEqual(module.verify_build_args(self.src, args, self.lock, self.root), args.resolve())
            stale = self.src / 'out/NeAntikStable156_48/args.gn'
            stale.parent.mkdir(parents=True)
            stale.write_bytes(args.read_bytes())
            with self.assertRaisesRegex(ValueError, 'Expected exact M156.80'):
                module.verify_build_args(self.src, stale, self.lock, self.root)
