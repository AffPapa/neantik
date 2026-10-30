import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'package-owned-webkit-release.py'
SPEC = importlib.util.spec_from_file_location('v468_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class NoticeStub:
    class NoticeError(RuntimeError): pass
    @staticmethod
    def _v382_runtime_hashes(root, offer, digest): return {}
    @staticmethod
    def _physical_path_beneath(root, relative, label):
        path = root / relative
        if path.is_symlink() or not path.is_file(): raise NoticeStub.NoticeError(label)
        return path

class StabilizedBuildBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.receipt = self.root / MODULE.V468_BUILD_RECEIPT_PATH
        self.receipt.parent.mkdir(parents=True)
        shutil.copyfile(MODULE.V468_LOCAL_BUILD_RECEIPT, self.receipt)
        self.entry = {'path': MODULE.V468_BUILD_RECEIPT_PATH.as_posix(),
                      'sha256': MODULE.V468_BUILD_RECEIPT_SHA256,
                      'bytes': self.receipt.stat().st_size, 'includedInOfferFolder': True}
        self.manifest = {'currentWebKitV467StabilizedRuntime': {'present': True},
                         'currentWebKitV468BuildReceipt': {'path': self.entry['path'], 'sha256': self.entry['sha256']},
                         'sourceOfferComponents': [self.entry]}
        self.patch = mock.patch.object(MODULE, '_load_module', return_value=NoticeStub)
        self.patch.start(); self.addCleanup(self.patch.stop)

    def write_manifest(self):
        data = (json.dumps(self.manifest, sort_keys=True) + '\n').encode()
        (self.root / 'manifest.json').write_bytes(data)
        return hashlib.sha256(data).hexdigest()

    def test_selects_only_exact_stabilized_receipt(self):
        result = MODULE.select_stabilized_build_binding(self.root, self.write_manifest(), {'derivedArchiveSHA256': 'x'})
        self.assertEqual(result['buildReceiptSHA256'], MODULE.V468_BUILD_RECEIPT_SHA256)
        self.assertEqual(result['derivedArchiveSHA256'], 'x')

    def test_missing_receipt_tamper_or_hybrid_rejected(self):
        del self.manifest['currentWebKitV468BuildReceipt']
        with self.assertRaises(MODULE.PackageError): MODULE.select_stabilized_build_binding(self.root, self.write_manifest(), {})
        self.manifest['currentWebKitV468BuildReceipt'] = {'path': self.entry['path'], 'sha256': self.entry['sha256']}
        self.receipt.write_bytes(self.receipt.read_bytes() + b' ')
        with self.assertRaises(MODULE.PackageError): MODULE.select_stabilized_build_binding(self.root, self.write_manifest(), {})
        shutil.copyfile(MODULE.V468_LOCAL_BUILD_RECEIPT, self.receipt)
        self.manifest['currentWebKitV465BaselineRuntime'] = {'present': True}
        with self.assertRaises(MODULE.PackageError): MODULE.select_stabilized_build_binding(self.root, self.write_manifest(), {})

    def test_historical_offer_remains_unchanged(self):
        self.manifest = {'sourceOfferComponents': []}
        old = {'buildReceiptSHA256': 'historic'}
        self.assertIs(MODULE.select_stabilized_build_binding(self.root, self.write_manifest(), old), old)

if __name__ == '__main__': unittest.main()
