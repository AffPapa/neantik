import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "webkit_runtime_notices.py"
SPEC = importlib.util.spec_from_file_location("webkit_offer_identity", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WebKitOfferIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def manifest(self, data):
        content = (json.dumps(data, sort_keys=True) + "\n").encode()
        (self.root / "manifest.json").write_bytes(content)
        return hashlib.sha256(content).hexdigest()

    def test_expected_identity_requires_root_and_matching_manifest(self):
        with self.assertRaises(MODULE.NoticeError):
            MODULE._v382_runtime_hashes(self.root, None, "0" * 64)
        self.manifest({})
        with self.assertRaises(MODULE.NoticeError):
            MODULE._v382_runtime_hashes(self.root, self.root, "0" * 64)
        with self.assertRaises(MODULE.NoticeError):
            MODULE._v382_runtime_hashes(self.root, self.root, "not-a-sha")

    def test_matching_new_manifest_cannot_omit_required_bindings(self):
        for value in ({}, {"currentWebKitV382FilteredModelSource": {}}):
            digest = self.manifest(value)
            with self.assertRaises(MODULE.NoticeError):
                MODULE._v382_runtime_hashes(self.root, self.root, digest)

    def test_legacy_no_offer_behavior_is_preserved(self):
        self.assertIsNone(MODULE._v382_runtime_hashes(self.root, None))


if __name__ == "__main__":
    unittest.main()
