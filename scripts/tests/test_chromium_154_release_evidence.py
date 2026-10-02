from pathlib import Path
import hashlib
import json
import importlib.util
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'chromium_154_release_evidence.py'
SPEC = importlib.util.spec_from_file_location('m154_release_evidence', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SnapshotBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'snapshot.json'
        self.path.write_bytes(b'{"entries": []}\n')
        self.digest = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.binding = {'sha256': self.digest}

    def test_separate_input_manifest_and_snapshot_are_bound(self):
        MODULE.verify_snapshot_binding(self.binding, {
            'sourceInputManifestSHA256': 'a' * 64,
            'sourceSnapshotSHA256': self.digest,
        }, self.path)

    def test_legacy_snapshot_alias_remains_verified(self):
        MODULE.verify_snapshot_binding(self.binding, {
            'sourceInputManifestSHA256': self.digest,
        }, self.path)

    def test_explicit_bad_binding_never_falls_back_to_legacy(self):
        for value in (None, '', 'invalid', '0' * 64):
            with self.subTest(value=value), self.assertRaises(MODULE.M154EvidenceError):
                MODULE.verify_snapshot_binding(self.binding, {
                    'sourceInputManifestSHA256': self.digest,
                    'sourceSnapshotSHA256': value,
                }, self.path)

    def test_changed_bytes_and_candidate_digest_are_rejected(self):
        contract = {'sourceSnapshotSHA256': self.digest}
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_snapshot_binding({'sha256': '0' * 64}, contract, self.path)
        self.path.write_bytes(b'changed')
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_snapshot_binding(self.binding, contract, self.path)

    def test_symlink_and_missing_snapshot_are_rejected(self):
        link = self.path.with_name('link.json')
        link.symlink_to(self.path)
        for path in (link, self.path.with_name('missing.json')):
            with self.subTest(path=path), self.assertRaises(MODULE.M154EvidenceError):
                MODULE.verify_snapshot_binding(self.binding, {
                    'sourceSnapshotSHA256': self.digest,
                }, path)


class InputManifestBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'manifest.json'
        self.manifest = {
            'chromiumVersion': MODULE.VERSION,
            'sourceSnapshotSHA256': 'a' * 64,
            'buildArgsSHA256': 'b' * 64,
        }
        self.contract = dict(self.manifest)
        self.write_manifest()

    def write_manifest(self):
        self.path.write_text(json.dumps(self.manifest))
        self.contract['sourceInputManifestSHA256'] = MODULE.sha256_file(self.path)

    def test_actual_manifest_bytes_are_bound(self):
        self.assertEqual(MODULE.verify_input_manifest_binding(self.contract, self.path), self.manifest)
        self.path.write_text('{}')
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_input_manifest_binding(self.contract, self.path)

    def test_rehashed_inconsistent_metadata_rejected(self):
        for key in ('sourceSnapshotSHA256', 'buildArgsSHA256', 'chromiumVersion'):
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = 'c' * 64
                self.write_manifest()
                with self.assertRaises(MODULE.M154EvidenceError):
                    MODULE.verify_input_manifest_binding(self.contract, self.path)
                self.manifest[key] = original

    def test_symlink_missing_and_local_path_rejected(self):
        link = self.path.with_name('link.json')
        link.symlink_to(self.path)
        for path in (link, self.path.with_name('missing.json')):
            with self.assertRaises(MODULE.M154EvidenceError):
                MODULE.verify_input_manifest_binding(self.contract, path)
        self.manifest['path'] = '/Users/private/input'
        self.write_manifest()
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_input_manifest_binding(self.contract, self.path)

    def test_contract_does_not_promote_pending_reconstruction(self):
        runtime = Path(self.temp.name) / 'runtime'
        runtime.mkdir()
        manifest_path = runtime / 'chromium-154-source-input-manifest.json'
        self.manifest.update({'status': 'source-evidence-pending', 'sourceInputsReady': False})
        manifest_path.write_text(json.dumps(self.manifest))
        contract = {
            'schemaVersion': 2, 'status': 'source-qualified',
            'targetChromiumVersion': MODULE.VERSION, 'targetArchitecture': 'arm64',
            'sourceMode': 'official-chromium-owned-macos-port',
            'safeBrowsingMode': 0, 'enterpriseCloudContentAnalysis': True,
            'officialChromiumBase': {'commit': MODULE.COMMIT, 'tree': MODULE.TREE},
            'sourceSnapshotSHA256': self.manifest['sourceSnapshotSHA256'],
            'buildArgsSHA256': self.manifest['buildArgsSHA256'],
            'portExperimentSHA256': 'c' * 64,
            'sourceInputManifestSHA256': MODULE.sha256_file(manifest_path),
        }
        contract_path = runtime / 'contract.json'
        contract_path.write_text(json.dumps(contract))
        with self.assertRaisesRegex(MODULE.M154EvidenceError, 'not qualified'):
            MODULE.verify_contract(contract, contract_path=contract_path, project_root=runtime.parent)
        # Schema 1 must not provide an alternate route around the new gate.
        contract['schemaVersion'] = 1
        with self.assertRaisesRegex(MODULE.M154EvidenceError, 'require contract schema 2'):
            MODULE.verify_contract(contract, contract_path=contract_path, project_root=runtime.parent)


if __name__ == '__main__':
    unittest.main()


class UnsignedBinaryBindingTests(unittest.TestCase):
    def setUp(self):
        import plistlib
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Runtime.app'
        self.exe = self.app / 'Contents/MacOS/NeAntik Browser'
        self.framework = self.app / 'Contents/Frameworks/NeAntik Browser Framework.framework/Versions' / MODULE.VERSION / 'NeAntik Browser Framework'
        self.args = Path(self.temp.name) / 'args.gn'
        for path in (self.exe, self.framework, self.args):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(path.name.encode())
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'NeAntik Browser',
            'CFBundleShortVersionString': MODULE.VERSION,
        }))
        self.document = {'binaryBinding': {
            key: MODULE.sha256_file(path) for path, key in (
                (self.exe, 'candidateExecutableSHA256'),
                (self.framework, 'candidateFrameworkSHA256'),
                (self.args, 'argsGNSHA256'),
            )
        }}

    def test_exact_build_bytes_pass(self):
        MODULE.verify_unsigned_binary_binding(self.app, self.args, self.document)

    def test_each_modified_input_rejected(self):
        for path in (self.exe, self.framework, self.args):
            original = path.read_bytes()
            path.write_bytes(original + b'tampered')
            with self.subTest(path=path), self.assertRaises(MODULE.M154EvidenceError):
                MODULE.verify_unsigned_binary_binding(self.app, self.args, self.document)
            path.write_bytes(original)

    def test_missing_framework_binding_rejected(self):
        del self.document['binaryBinding']['candidateFrameworkSHA256']
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_unsigned_binary_binding(self.app, self.args, self.document)

    def test_external_binary_symlink_rejected(self):
        outside = Path(self.temp.name) / 'outside'
        outside.write_bytes(self.framework.read_bytes())
        self.framework.unlink()
        self.framework.symlink_to(outside)
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_unsigned_binary_binding(self.app, self.args, self.document)
