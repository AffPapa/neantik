"""Actual canonical source-proof copy and corruption controls; no runtime claim."""
import json
from pathlib import Path
import tempfile
import unittest
import chromium_15612_packaged_evidence as packaged
import chromium_15612_release_evidence as source


class PackagedM156Tests(unittest.TestCase):
    project = Path(__file__).resolve().parents[2]

    def test_exact_copy_and_changed_missing_extra_or_linked_proof_refused(self):
        lock = json.loads((self.project / 'runtime/fingerprint-chromium-15612.lock.json').read_text())
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)
            packaged.process(self.project, evidence, lock, copy=True)
            packaged.process(self.project, evidence, lock)
            leaf = evidence / 'chromium-15612-source-contract.json'
            original = leaf.read_bytes()
            leaf.write_bytes(original + b' ')
            with self.assertRaisesRegex(ValueError, 'differs'):
                packaged.process(self.project, evidence, lock)
            leaf.unlink()
            with self.assertRaises(ValueError):
                packaged.process(self.project, evidence, lock)
            leaf.symlink_to(self.project / 'runtime/chromium-15612-source-contract.json')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                packaged.process(self.project, evidence, lock)
            leaf.unlink()
            leaf.write_bytes(original)
            extra = evidence / 'chromium-15612-source-evidence/unreviewed.json'
            extra.write_text('{}')
            with self.assertRaisesRegex(ValueError, 'extra'):
                packaged.process(self.project, evidence, lock)
            extra.unlink()
            packaged.process(self.project, evidence, lock)
            lock['fingerprintChromium']['chromiumVersion'] = '156.0.8078.13'
            with self.assertRaises(ValueError):
                packaged.process(self.project, evidence, lock)

    def test_live_root_still_cannot_masquerade_as_fresh_source_scan(self):
        candidate = json.loads((self.project / 'runtime/chromium-15612-port-candidate.json').read_text())
        with self.assertRaisesRegex(ValueError, 'explicit final9 FD observation'):
            source.verify_candidate_document(candidate, project_root=self.project, source_root=Path('/tmp'))

    def test_private_paths_are_not_on_copy_allowlist(self):
        names = packaged.names(self.project)
        self.assertGreater(len(names), 60)
        self.assertTrue(all(not name.startswith('/') and '..' not in name.split('/') for name in names))
        self.assertFalse(any('producer-launch' in name or name.startswith('postbuild-full-source-attempt-9-launch') for name in names))
