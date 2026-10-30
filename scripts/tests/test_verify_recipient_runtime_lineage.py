import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-recipient-runtime-lineage.py'
SPEC = importlib.util.spec_from_file_location('recipient_lineage_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RecipientRuntimeLineageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.source, self.signed, self.binding = root / 'source', root / 'signed', root / 'binding.json'
        self.relative = Path('WebKit.framework/Versions/A/WebKit')
        for base, content in ((self.source, b'source'), (self.signed, b'signed')):
            path = base / self.relative
            path.parent.mkdir(parents=True)
            path.write_bytes(bytes.fromhex('cffaedfe') + content)
        digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        self.row = {'path': self.relative.as_posix(), 'sourceInputSHA256': digest(self.source / self.relative),
                    'relocatedSHA256': 'a' * 64, 'recipientSignedSHA256': digest(self.signed / self.relative)}
        self.write_binding([self.row])
        self.signatures = mock.patch.object(MODULE.RESIGN.PACKAGER, 'verify_runtime_frameworks')
        self.entitlements = mock.patch.object(MODULE.RESIGN.PACKAGER, 'verify_release_xpc_entitlements')
        self.verify_signature = self.signatures.start(); self.verify_entitlements = self.entitlements.start()
        self.addCleanup(self.signatures.stop); self.addCleanup(self.entitlements.stop)

    def write_binding(self, rows):
        self.binding.write_text(json.dumps({'schemaVersion': 1, 'status': 'recipient-signed-runtime-image-binding',
                                            'imageCount': len(rows), 'images': rows}))

    def verify(self):
        return MODULE.verify_lineage(self.source, self.signed, self.binding, 'H6VGU2M6JD')

    def test_valid_correspondence_requires_signature_and_entitlements(self):
        result = self.verify()
        self.assertEqual(result['imageCount'], 1)
        self.assertFalse(result['releaseQualified'])
        self.verify_signature.assert_called_once_with(self.signed, 'H6VGU2M6JD')
        self.verify_entitlements.assert_called_once_with(self.signed)

    def test_source_or_signed_tampering_refused(self):
        for target in (self.source, self.signed):
            file = target / self.relative
            original = file.read_bytes()
            file.write_bytes(original + b'changed')
            with self.assertRaisesRegex(MODULE.LineageError, 'digest mismatch'): self.verify()
            file.write_bytes(original)

    def test_duplicate_and_traversal_paths_refused(self):
        for rows in ([self.row, self.row], [{**self.row, 'path': '../escape'}]):
            self.write_binding(rows)
            with self.assertRaisesRegex(MODULE.LineageError, 'path invalid'): self.verify()

    def test_unlisted_image_and_bad_team_refused(self):
        (self.source / 'extra').write_bytes(bytes.fromhex('cffaedfe') + b'extra')
        with self.assertRaisesRegex(MODULE.LineageError, 'inventory mismatch'): self.verify()
        with self.assertRaisesRegex(MODULE.LineageError, 'expected team'): MODULE.verify_lineage(self.source, self.signed, self.binding, 'invalid')

    def test_signature_failure_propagates(self):
        self.verify_signature.side_effect = MODULE.RESIGN.PACKAGER.ContractError('wrong signing team')
        with self.assertRaisesRegex(MODULE.RESIGN.PACKAGER.ContractError, 'wrong signing team'): self.verify()

    def test_pinned_baseline_distinguishes_changed_and_extra_images(self):
        receipt = self.binding.parent / 'baseline.json'
        receipt.write_text(json.dumps({'outputs': [{'path': self.relative.as_posix(), 'sha256': 'b' * 64}]}))
        digest = hashlib.sha256(receipt.read_bytes()).hexdigest()
        result = MODULE.verify_lineage(self.source, self.signed, self.binding, 'H6VGU2M6JD', receipt, digest)
        self.assertEqual(result['baselineComparison']['differentImages'], [self.relative.as_posix()])
        self.assertEqual(result['baselineComparison']['additionalSourceImages'], [])
        self.assertFalse(result['releaseQualified'])
        with self.assertRaisesRegex(MODULE.LineageError, 'identity mismatch'):
            MODULE.verify_lineage(self.source, self.signed, self.binding, 'H6VGU2M6JD', receipt, '0' * 64)

    def test_baseline_requires_both_path_and_hash_and_unique_paths(self):
        with self.assertRaisesRegex(MODULE.LineageError, 'supplied together'):
            MODULE.verify_lineage(self.source, self.signed, self.binding, 'H6VGU2M6JD', self.binding, None)
        path = self.relative.as_posix(); receipt = self.binding.parent / 'baseline.json'
        receipt.write_text(json.dumps({'outputs': [{'path': path, 'sha256': 'a' * 64}, {'path': path, 'sha256': 'b' * 64}]}))
        with self.assertRaisesRegex(MODULE.LineageError, 'baseline output invalid'):
            MODULE.compare_baseline({path: 'a' * 64}, receipt, hashlib.sha256(receipt.read_bytes()).hexdigest())
