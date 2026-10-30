import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-recipient-v446-capability.py'
SPEC = importlib.util.spec_from_file_location('v446_capability_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class V446CapabilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.offer, self.baseline, self.modified, self.signed = (root / x for x in ('offer', 'baseline', 'modified', 'signed'))
        for directory in (self.offer, self.baseline, self.modified, self.signed):
            directory.mkdir()
        self.source, self.binding = root / 'source', root / 'binding'
        self.source.write_bytes(b'source'); self.binding.write_bytes(b'exact binding')
        identity_path = self.offer / MODULE.IDENTITY_PATH
        identity_path.parent.mkdir(parents=True)
        self.paths = [MODULE.GPU_PATH] + [f'lib{i}.dylib' for i in range(15)]
        self.originals = {p: f'{i:064x}' for i, p in enumerate(self.paths, 1)}
        self.changed = dict(self.originals); self.changed[MODULE.GPU_PATH] = 'f' * 64
        identity_path.write_text(json.dumps({'stageAndSignedImages': [
            {'path': p, 'buildStageSHA256': v} for p, v in self.originals.items()]}))
        manifest_path = self.offer / 'manifest.json'
        manifest_path.write_text(json.dumps({'currentWebKitV465BaselineRuntime':
                                               {'path': MODULE.IDENTITY_PATH, 'sha256': sha(identity_path)}}))
        for directory in (self.baseline, self.modified, self.signed):
            asset = directory / MODULE.ASSETS_PATH
            asset.parent.mkdir(parents=True)
            asset.write_bytes(b'assets')
        gpu = self.modified / MODULE.GPU_PATH
        gpu.parent.mkdir(parents=True); gpu.write_bytes(b'gpu')
        changes = {'OFFER_SHA': sha(manifest_path), 'IDENTITY_SHA': sha(identity_path),
                   'BINDING_SHA': sha(self.binding), 'ASSETS_SHA': sha(self.baseline / MODULE.ASSETS_PATH)}
        self.constants = mock.patch.multiple(MODULE, **changes); self.constants.start(); self.addCleanup(self.constants.stop)
        self.mock_hashes = mock.patch.object(MODULE.LINEAGE, 'image_hashes', side_effect=self.hashes)
        self.mock_hashes.start(); self.addCleanup(self.mock_hashes.stop)
        self.mock_marker = mock.patch.object(MODULE.MARKER, 'verify', return_value={'status': 'local-marker-replay-and-image-pass'})
        self.mock_marker.start(); self.addCleanup(self.mock_marker.stop)
        self.mock_lineage = mock.patch.object(MODULE.LINEAGE, 'verify_lineage', return_value={'imageCount': 16, 'releaseQualified': False})
        self.lineage = self.mock_lineage.start(); self.addCleanup(self.mock_lineage.stop)

    def hashes(self, root):
        return dict(self.originals if root == self.baseline else self.changed)

    def verify(self):
        return MODULE.verify(self.offer, self.source, self.baseline, self.modified, self.signed, self.binding)

    def test_exact_case_is_private_and_requires_fixed_team(self):
        result = self.verify()
        self.assertEqual(result['status'], 'private-v446-evidence-pass')
        self.assertFalse(result['releaseQualified'])
        self.assertIn('no complete legal or notice qualification', result['limitations'])
        self.lineage.assert_called_once_with(self.modified, self.signed, self.binding, MODULE.TEAM)

    def test_offer_or_identity_tampering_refused(self):
        for path in (self.offer / 'manifest.json', self.offer / MODULE.IDENTITY_PATH):
            before = path.read_bytes(); path.write_bytes(before + b'x')
            with self.assertRaisesRegex(MODULE.CapabilityError, 'identity mismatch'): self.verify()
            path.write_bytes(before)

    def test_second_changed_image_and_missing_image_refused(self):
        self.changed['lib0.dylib'] = 'e' * 64
        with self.assertRaisesRegex(MODULE.CapabilityError, 'differ outside WebGPU'): self.verify()
        self.changed.pop('lib0.dylib')
        with self.assertRaisesRegex(MODULE.CapabilityError, 'inventory mismatch'): self.verify()

    def test_unchanged_gpu_is_refused(self):
        self.changed[MODULE.GPU_PATH] = self.originals[MODULE.GPU_PATH]
        with self.assertRaisesRegex(MODULE.CapabilityError, 'marker image unchanged'): self.verify()

    def test_asset_and_binding_tampering_refused(self):
        for path in (self.binding, self.signed / MODULE.ASSETS_PATH):
            before = path.read_bytes(); path.write_bytes(before + b'x')
            with self.assertRaises(MODULE.CapabilityError): self.verify()
            path.write_bytes(before)

    def test_marker_failure_and_signature_failure_are_not_ignored(self):
        MODULE.MARKER.verify.side_effect = ValueError('modified source mismatch')
        with self.assertRaisesRegex(ValueError, 'modified source mismatch'): self.verify()
        MODULE.MARKER.verify.side_effect = None
        self.lineage.side_effect = MODULE.LINEAGE.RESIGN.PACKAGER.ContractError('wrong team')
        with self.assertRaisesRegex(MODULE.LINEAGE.RESIGN.PACKAGER.ContractError, 'wrong team'): self.verify()

    def test_unqualified_signed_result_refused(self):
        self.lineage.return_value = {'imageCount': 16, 'releaseQualified': True}
        with self.assertRaisesRegex(MODULE.CapabilityError, 'signed runtime verification failed'): self.verify()

    def prepare_v508(self):
        components = []
        def component(path):
            components.append({'path': path.relative_to(self.offer).as_posix(),
                               'bytes': path.stat().st_size, 'sha256': sha(path),
                               'includedInOfferFolder': True})
        for group in range(8):
            directory = self.offer / 'overlays' / f'group{group}'
            directory.mkdir(parents=True)
            rows = []
            for i in range(group * 7, min(group * 7 + 7, 55)):
                relative = f'Source/WebCore/Resources/resource{i}.png'
                asset = directory / relative
                asset.parent.mkdir(parents=True, exist_ok=True)
                asset.write_bytes(f'asset{i}'.encode())
                component(asset)
                rows.append({'path': relative, 'bytes': asset.stat().st_size,
                             'sha256': sha(asset), 'replacesRuntimeSHA256': 'a' * 64})
                for tree in (self.modified, self.signed):
                    dest = tree / 'WebCore.framework/Versions/A/Resources' / asset.name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(asset.read_bytes())
            attr = directory / 'ATTRIBUTION.json'
            attr.write_text(json.dumps({'assets': rows})); component(attr)
        manifest = self.offer / 'manifest.json'
        data = json.loads(manifest.read_text())
        data.update(sourceOfferComponents=components, sourceOfferComponentCount=len(components))
        manifest.write_text(json.dumps(data))
        rows = [{'path': name, 'sourceInputSHA256': self.changed[name],
                 'relocatedSHA256': 'a' * 64, 'recipientSignedSHA256': 'b' * 64}
                for name in self.paths]
        self.binding.write_text(json.dumps({'images': rows}))
        receipt = self.binding.parent / 'receipt.json'
        receipt.write_text(json.dumps({'schemaVersion': 1, 'offerSHA256': sha(manifest),
                        'bindingSHA256': sha(self.binding), 'imageCount': 16,
                        'images': [{k: row[k] for k in ('path', 'sourceInputSHA256',
                                                        'recipientSignedSHA256')} for row in rows]}))
        return receipt, {'OFFER_SHA': sha(manifest), 'V508_BINDING_SHA': sha(self.binding),
                         'V508_RECEIPT_SHA': sha(receipt)}

    def test_v508_requires_fixed_receipt_and_55_overlay_postimages(self):
        receipt, constants = self.prepare_v508()
        with mock.patch.multiple(MODULE, **constants):
            with self.assertRaisesRegex(MODULE.CapabilityError, 'receipt required'): self.verify()
            result = MODULE.verify(self.offer, self.source, self.baseline, self.modified,
                                   self.signed, self.binding, receipt)
            self.assertEqual(result['qaVariant'], 'V508')
            self.assertFalse(result['releaseQualified'])
            for root in (self.modified, self.signed):
                target = root / 'WebCore.framework/Versions/A/Resources/resource0.png'
                original = target.read_bytes(); target.write_bytes(b'tampered')
                with self.assertRaisesRegex(MODULE.CapabilityError, 'postimage mismatch'):
                    MODULE.verify(self.offer, self.source, self.baseline, self.modified,
                                  self.signed, self.binding, receipt)
                target.write_bytes(original)
            receipt.write_bytes(receipt.read_bytes() + b'x')
            with self.assertRaisesRegex(MODULE.CapabilityError, 'identity mismatch'):
                MODULE.verify(self.offer, self.source, self.baseline, self.modified,
                              self.signed, self.binding, receipt)

    def test_v508_changed_overlay_component_is_refused(self):
        receipt, constants = self.prepare_v508()
        with mock.patch.multiple(MODULE, **constants):
            asset = self.offer / 'overlays/group0/Source/WebCore/Resources/resource0.png'
            asset.write_bytes(b'tampered')
            with self.assertRaisesRegex(MODULE.CapabilityError, 'asset component mismatch'):
                MODULE.verify(self.offer, self.source, self.baseline, self.modified,
                              self.signed, self.binding, receipt)

    def test_v447_rejects_v508_receipt(self):
        with self.assertRaisesRegex(MODULE.CapabilityError, 'cannot be used for V447'):
            MODULE.verify(self.offer, self.source, self.baseline, self.modified,
                          self.signed, self.binding, self.binding)
