import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'webkit_runtime_notices.py'
SPEC = importlib.util.spec_from_file_location('v472_receipts_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ROOT = SCRIPT.parents[1]

class PortableReceiptTests(unittest.TestCase):
    def test_exact_portable_receipts_preserve_provenance_and_redact_path(self):
        cases = (
            ('neantik-v417-source-rebound-prepared-bundle-20261028.json', MODULE.V473_PORTABLE_V417_SHA256, MODULE.V417_PREPARED_BUNDLE_RECEIPT_SHA256),
            ('neantik-v420-current-four-image-source-notice-bind-20261028.json', MODULE.V472_PORTABLE_V420_SHA256, MODULE.V420_CURRENT_IMAGE_BINDING_RECEIPT_SHA256),
        )
        for name, expected, original in cases:
            with self.subTest(name=name):
                raw = (ROOT / 'docs/evidence/v472-portable-receipts' / name).read_bytes()
                data = json.loads(raw)
                self.assertEqual(hashlib.sha256(raw).hexdigest(), expected)
                self.assertNotIn(b'/Users/', raw)
                self.assertEqual(data['priorCurrent']['path'], '[local checkpoint path redacted]')
                self.assertEqual(data['portableRedaction']['originalReceiptSHA256'], original)
                expected_fields = ['priorCurrent.path']
                if name.startswith('neantik-v417'):
                    expected_fields += ['candidate.root', 'candidate.appPath']
                    self.assertNotIn(b'/private/' + b'tmp/neantik-', raw)
                self.assertEqual(data['portableRedaction']['redactedFields'], expected_fields)

if __name__ == '__main__': unittest.main()
