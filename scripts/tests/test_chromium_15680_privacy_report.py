import copy
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chromium_15680_privacy_report import NAME, preserved_report_bytes

PROJECT = Path(__file__).resolve().parents[2]

class PrivacyReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='neantik-privacy-report-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / 'runtime').mkdir()
        self.raw = (PROJECT / 'runtime' / NAME).read_bytes()
        (self.root / 'runtime' / NAME).write_bytes(self.raw)
        self.observed = json.loads(self.raw)
        self.observed['createdAt'] = datetime.now(timezone.utc).isoformat()

    def test_reobserving_same_signed_bytes_retains_original_report(self):
        self.assertEqual(preserved_report_bytes(self.observed, self.root), self.raw)
        self.assertNotEqual(self.observed['createdAt'], json.loads(self.raw)['createdAt'])

    def test_changed_framework_fields_and_unknown_schema_cannot_reuse_report(self):
        for field in ['framework', 'executable']:
            observed = copy.deepcopy(self.observed); observed[field]['sha256'] = '0' * 64
            with self.assertRaises(ValueError): preserved_report_bytes(observed, self.root)
        self.observed['unexpected'] = True
        with self.assertRaises(ValueError): preserved_report_bytes(self.observed, self.root)

    def test_mutated_or_linked_frozen_report_is_not_authority(self):
        path = self.root / 'runtime' / NAME
        path.write_bytes(self.raw + b'\n')
        with self.assertRaises(ValueError): preserved_report_bytes(self.observed, self.root)
        path.unlink(); path.symlink_to(PROJECT / 'runtime' / NAME)
        with self.assertRaises(ValueError): preserved_report_bytes(self.observed, self.root)

    def test_report_timestamp_cannot_run_backwards(self):
        self.observed['createdAt'] = '2020-01-01T00:00:00Z'
        with self.assertRaises(ValueError): preserved_report_bytes(self.observed, self.root)

if __name__ == '__main__': unittest.main()
