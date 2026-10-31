"""A release observation may change without rewriting built-source evidence."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import chromium_15674_release_evidence as evidence


class HistoricalBaselineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / 'runtime'
        originals = ROOT / 'runtime'
        contract = json.loads((originals / evidence.CONTRACT).read_text())
        self.digest = contract['securityBaselineSHA256']
        for name in (evidence.CONTRACT, evidence.PLAN, evidence.ADOPTION,
                     'licenses/Chromium-LICENSE', 'security-baseline.json',
                     'apple-device-tuples.json', 'nevision-patches/series.json',
                     f'security-baselines/{self.digest}.json'):
            target = self.runtime / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(originals / name, target)
        self.archived = self.runtime / 'security-baselines' / f'{self.digest}.json'
        self.assertNotEqual(hashlib.sha256((self.runtime / 'security-baseline.json').read_bytes()).hexdigest(), self.digest)

    def test_contract_uses_original_baseline_after_publication_refresh(self):
        self.assertEqual(evidence.verify_contract(self.root)['securityBaselineSHA256'], self.digest)
        provenance = self.root / 'provenance.json'
        provenance.write_text('{}')
        with mock.patch.object(evidence, 'verify_provenance'):
            lock = evidence.expected_lock(provenance, self.root)
        self.assertEqual(lock['ownedManifests']['securityBaselineSHA256'], self.digest)

    def test_missing_modified_or_symlinked_archive_is_rejected(self):
        for scenario in ('missing', 'modified', 'symlink'):
            with self.subTest(scenario=scenario):
                original = self.archived.read_bytes()
                self.archived.unlink()
                if scenario == 'modified':
                    self.archived.write_bytes(original + b' ')
                elif scenario == 'symlink':
                    self.archived.symlink_to(self.runtime / 'security-baseline.json')
                with self.assertRaises(evidence.M15674EvidenceError):
                    evidence.verify_contract(self.root)
                if self.archived.exists() or self.archived.is_symlink():
                    self.archived.unlink()
                self.archived.write_bytes(original)


if __name__ == '__main__':
    unittest.main()
