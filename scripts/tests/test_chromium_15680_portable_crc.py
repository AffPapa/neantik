import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import chromium_15680_portable_crc as crc
import runtime_source_provenance as provenance

PROJECT = Path(__file__).resolve().parents[2]


class PortableCRCEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        runtime = self.root / 'runtime'
        runtime.mkdir()
        for name in ('chromium-15680-portable-crc.json', 'chromium-15680-portable-crc.patch',
                     'chromium-15680-build-evidence.json'):
            shutil.copyfile(PROJECT / 'runtime' / name, runtime / name)
        shutil.copytree(PROJECT / 'runtime/chromium-15680-portable-crc',
                        runtime / 'chromium-15680-portable-crc')
        self.contract = json.loads((PROJECT / 'runtime/chromium-15680-source-contract.json').read_text())
        self.manifest = runtime / 'chromium-15680-portable-crc.json'
        self.data = json.loads(self.manifest.read_text())

    def reseal_manifest(self):
        self.manifest.write_text(json.dumps(self.data))
        self.contract['portableCRC']['sha256'] = crc.digest(self.manifest)

    def test_real_recorded_derivation_and_legacy_contract(self):
        self.assertEqual(crc.verify(self.root, self.contract)['archive']['afterMemberCount'], 295)
        self.assertIsNone(crc.verify(self.root, {}))

    def test_tampered_source_patch_is_rejected(self):
        (self.root / crc.PATCH).write_text('modified')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            crc.verify(self.root, self.contract)

    def test_original_framework_cannot_substitute_for_derived_output(self):
        self.data['outputs']['frameworkSHA256'] = self.data['baseFrameworkSHA256']
        self.reseal_manifest()
        with self.assertRaisesRegex(ValueError, 'original framework'):
            crc.verify(self.root, self.contract)

    def test_arbitrary_source_overlay_is_rejected_even_when_manifest_is_resealed(self):
        self.data['sourceOverlay']['libavutil/crc.c']['afterSHA256'] = '0' * 64
        self.reseal_manifest()
        with self.assertRaisesRegex(ValueError, 'source overlay mismatch'):
            crc.verify(self.root, self.contract)

    def test_failed_link_cannot_be_declared_as_completed_derivation(self):
        self.data['linkExitCode'] = 1
        self.reseal_manifest()
        with self.assertRaisesRegex(ValueError, 'both succeed'):
            crc.verify(self.root, self.contract)

    def test_extra_archive_member_removal_is_rejected(self):
        self.data['archive']['afterMemberCount'] = 294
        self.reseal_manifest()
        with self.assertRaisesRegex(ValueError, 'archive derivation'):
            crc.verify(self.root, self.contract)

    def test_symlinked_evidence_is_rejected(self):
        path = self.root / self.data['inputs']['configuration']['file']
        real = path.with_name('real-config.h')
        path.rename(real)
        path.symlink_to(real.name)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            crc.verify(self.root, self.contract)

    def test_stale_lock_cannot_select_portable_notices(self):
        (self.root / 'runtime/chromium-15680-source-contract.json').write_text(json.dumps(self.contract))
        with self.assertRaisesRegex(ValueError, 'runtime lock'):
            crc.for_lock(self.root, {'ownedInputs': {}})

    def test_changed_base_source_is_rejected(self):
        source = self.root / 'source'
        target = source / 'third_party/ffmpeg/libavutil/crc.c'
        target.parent.mkdir(parents=True)
        target.write_text('changed source')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            crc.verify_source(self.root, self.contract, source)

    def test_new_candidate_dispatch_accepts_bound_80_contract_without_legacy_mac_fields(self):
        contract = json.loads((PROJECT / 'runtime/chromium-15680-source-contract.json').read_text())
        lock = {'schemaVersion': 4, 'status': 'source-qualified',
                'fingerprintChromium': {'chromiumVersion': '156.0.8078.80'},
                'sourceContractSHA256': crc.digest(PROJECT / 'runtime/chromium-15680-source-contract.json'),
                'ownedInputs': {'portableCrcManifestSHA256': contract['portableCRC']['sha256']}}
        path = self.root / 'lock.json'
        path.write_text(json.dumps(lock))
        provenance.verify_runtime_lock_for_new_candidate(path, project_root=PROJECT)
        lock['sourceContractSHA256'] = '0' * 64
        path.write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, 'source contract mismatch'):
            provenance.verify_runtime_lock_for_new_candidate(path, project_root=PROJECT)


if __name__ == '__main__':
    unittest.main()
