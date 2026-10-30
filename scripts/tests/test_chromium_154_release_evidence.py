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


class DeviceMemoryHotfixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Path(self.temp.name) / 'runtime'
        evidence = self.runtime / 'chromium-154-source-evidence'
        patch_dir = self.runtime / 'nevision-patches/ports/chromium-154.0.8037.93/patches'
        evidence.mkdir(parents=True)
        patch_dir.mkdir(parents=True)
        self.files = []
        for relative, stem, old, new in (
            ('content/browser/client_hints/client_hints.cc',
             'device-memory-client-hints', 'browser-old\n', 'browser-new\n'),
            ('third_party/blink/renderer/core/loader/frame_fetch_context.cc',
             'device-memory-renderer-client-hints', 'renderer-old\n', 'renderer-new\n'),
        ):
            preimage = evidence / f'{stem}-preimage.cc'
            preimage.write_text(old)
            patch = patch_dir / f'{stem}.patch'
            patch.write_text(
                f'--- a/{relative}\n+++ b/{relative}\n'
                f'@@ -1 +1 @@\n-{old}+{new}'
            )
            self.files.append({
                'sourcePath': relative,
                'preimageSHA256': hashlib.sha256(old.encode()).hexdigest(),
                'postimageSHA256': hashlib.sha256(new.encode()).hexdigest(),
                'patchSHA256': MODULE.sha256_file(patch),
                'preimage': preimage,
                'patch': patch,
            })
        self.base = {'schemaVersion': 2, 'entriesSHA256': 'a' * 64}
        self.post = {'schemaVersion': 2, 'entriesSHA256': 'b' * 64}
        self.base_path = self.runtime / 'chromium-154-source-snapshot.json'
        self.post_path = self.runtime / 'chromium-154-posthotfix-source-snapshot.json'
        self.write_json(self.base_path, self.base)
        self.write_json(self.post_path, self.post)
        self.steps = [
            {'path': item['sourcePath'],
             'beforeSHA256': item['preimageSHA256'],
             'afterSHA256': item['postimageSHA256'],
             'patchSHA256': item['patchSHA256']}
            for item in self.files
        ]
        self.report = {
            'schemaVersion': 1, 'beforeSnapshot': self.base, 'afterSnapshot': self.post,
            'overlaySteps': self.steps, 'verifiedCaches': [], 'unexplainedChanges': 0,
            'releaseReady': False,
            'changes': [
                {'path': item['sourcePath'],
                 'before': {'sha256': item['preimageSHA256']},
                 'after': {'sha256': item['postimageSHA256']}}
                for item in self.files
            ],
        }
        self.report_path = evidence / 'device-memory-hotfix-transition.json'
        self.write_json(self.report_path, self.report)
        self.addendum_path = self.runtime / 'chromium-154-device-memory-hotfix.json'
        self.refresh_addendum()

    def write_json(self, path, value):
        path.write_text(json.dumps(value, sort_keys=True) + '\n')

    def refresh_addendum(self):
        self.addendum = {
            'schemaVersion': 2, 'status': 'two-file-source-hotfix', 'releaseReady': False,
            'files': [
                {key: item[key] for key in ('sourcePath', 'preimageSHA256',
                                            'postimageSHA256', 'patchSHA256')}
                for item in self.files
            ],
            'baseSnapshotSHA256': MODULE.sha256_file(self.base_path),
            'postSnapshotSHA256': MODULE.sha256_file(self.post_path),
            'transitionSHA256': MODULE.sha256_file(self.report_path),
        }
        self.write_json(self.addendum_path, self.addendum)
        self.document = {
            'sourceHotfixSHA256': MODULE.sha256_file(self.addendum_path),
            'postSourceSnapshotSHA256': MODULE.sha256_file(self.post_path),
        }

    def test_exact_two_file_replay_passes(self):
        self.assertEqual(MODULE.verify_device_memory_hotfix(self.document, self.runtime), self.post)

    def test_missing_or_tampered_binding_fails(self):
        for key in self.document:
            with self.subTest(key=key), self.assertRaises(MODULE.M154EvidenceError):
                MODULE.verify_device_memory_hotfix({**self.document, key: '0' * 64}, self.runtime)
        patch = self.files[1]['patch']
        patch.write_text(patch.read_text() + '# changed\n')
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_device_memory_hotfix(self.document, self.runtime)

    def test_second_source_change_and_false_preimage_fail(self):
        self.report['changes'].append({'path': 'extra.cc', 'before': {}, 'after': {}})
        self.write_json(self.report_path, self.report)
        self.refresh_addendum()
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_device_memory_hotfix(self.document, self.runtime)
        self.report['changes'].pop()
        self.write_json(self.report_path, self.report)
        self.refresh_addendum()
        self.files[0]['preimage'].write_text('different\n')
        with self.assertRaises(MODULE.M154EvidenceError):
            MODULE.verify_device_memory_hotfix(self.document, self.runtime)


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
        self.manifest['path'] = '/Users/test/input'
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


class TupleRuntimeQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Path(self.temp.name) / 'runtime'
        self.evidence_path = self.runtime / 'chromium-154-source-evidence/coherent-apple-device-tuples-runtime-qualification.json'
        self.evidence_path.parent.mkdir(parents=True)
        (self.runtime / 'chromium-154-port-candidate.json').write_text('{}')
        (self.runtime / 'apple-device-tuples.json').write_text('{}')
        self.candidate = {'binaryBinding': {'candidateFrameworkSHA256': 'a' * 64}}
        self.record = {
            'schemaVersion': 1, 'status': 'verified',
            'chromiumVersion': MODULE.VERSION,
            'guiProductionQualified': True, 'releaseReady': False,
            'sourceCandidateSHA256': MODULE.sha256_file(self.runtime / 'chromium-154-port-candidate.json'),
            'tupleCatalogSHA256': MODULE.sha256_file(self.runtime / 'apple-device-tuples.json'),
            'unsignedFrameworkSHA256': 'a' * 64,
            'deviceMemory': {
                'js': 8, 'coherent': True,
                'navigation': {'modern': '8', 'legacy': '8'},
                'subresource': {'modern': '8', 'legacy': '8'},
            },
        }
        for key in (
            'signedRuntimeExecutableSHA256', 'signedRuntimeFrameworkSHA256',
            'candidateManifestSHA256', 'authenticatedGUIEnvelopeSHA256',
            'publicSafeGUISummarySHA256',
        ):
            self.record[key] = 'b' * 64
        self.lock = {'verification': {
            'coherentAppleDeviceTuples': 'verified',
            'coherentAppleDeviceTuplesEvidence':
                'runtime/chromium-154-source-evidence/coherent-apple-device-tuples-runtime-qualification.json',
        }}
        self.write_record()

    def write_record(self):
        self.evidence_path.write_text(json.dumps(self.record))
        self.lock['verification']['coherentAppleDeviceTuplesEvidenceSHA256'] = MODULE.sha256_file(self.evidence_path)

    def test_bound_production_qualification_passes(self):
        MODULE.verify_tuple_runtime_qualification(self.lock, self.candidate, self.runtime)

    def test_tampered_or_rehashed_incoherent_evidence_fails(self):
        self.evidence_path.write_text('{}')
        with self.assertRaisesRegex(MODULE.M154EvidenceError, 'digest mismatch'):
            MODULE.verify_tuple_runtime_qualification(self.lock, self.candidate, self.runtime)
        self.record['deviceMemory']['subresource']['modern'] = '32'
        self.write_record()
        with self.assertRaisesRegex(MODULE.M154EvidenceError, 'incoherent'):
            MODULE.verify_tuple_runtime_qualification(self.lock, self.candidate, self.runtime)

    def test_production_claim_and_source_binding_are_required(self):
        self.record['guiProductionQualified'] = False
        self.write_record()
        with self.assertRaisesRegex(MODULE.M154EvidenceError, 'incomplete'):
            MODULE.verify_tuple_runtime_qualification(self.lock, self.candidate, self.runtime)
        self.record['guiProductionQualified'] = True
        self.record['unsignedFrameworkSHA256'] = 'c' * 64
        self.write_record()
        with self.assertRaisesRegex(MODULE.M154EvidenceError, 'unsigned framework'):
            MODULE.verify_tuple_runtime_qualification(self.lock, self.candidate, self.runtime)
