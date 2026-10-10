"""Generated cache is one exact derived artifact, never an ignore glob."""
import copy
import json
import sys
import unittest
import subprocess
import tempfile
import marshal
import struct
import importlib.util
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chromium_15540_generated_cache as module


class GeneratedCacheTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2]
        self.document = json.loads((root / 'runtime/chromium-15540-semantic-v3-generated-build-cache.json').read_text())
        self.cache = {'kind': 'file', 'path': module.CACHE, 'mode': 420, 'sizeBytes': 2178, 'sha256': module.CACHE_HASH}
        self.source = {'kind': 'file', 'path': module.SOURCE, 'mode': 420, 'sizeBytes': 2345, 'sha256': module.SOURCE_HASH}
        self.full = {'sourceFileCount': 2, 'entries': [self.source, self.cache]}

    def test_exact_document_and_one_derived_cache(self):
        module.verify_document(self.document)
        normalized = module.normalize(self.full, self.document)
        self.assertEqual(normalized['entries'], [self.source])
        self.assertEqual(normalized['sourceFileCount'], 1)
        self.assertEqual(self.full['sourceFileCount'], 2)

    def test_schema_boolean_and_claim_substitutions_rejected(self):
        for changes in ({'schemaVersion': True}, {'freshCompiledCodeMatches': 1},
                        {'releaseReady': 0}, {'sourceTimestampAndLengthMatch': False},
                        {'postBuildSnapshotSHA256': '0' * 64}):
            with self.assertRaises(ValueError):
                module.verify_document({**self.document, **changes})

    def test_cache_digest_mode_length_path_and_duplicates_rejected(self):
        for changes in ({'sha256': '0' * 64}, {'mode': 493}, {'sizeBytes': 2177},
                        {'path': 'other/__pycache__/whole_archive.cpython-314.pyc'}):
            full = copy.deepcopy(self.full)
            full['entries'][1].update(changes)
            with self.assertRaises(ValueError):
                module.normalize(full, self.document)
        for entries in ([self.source], [self.source, self.cache, self.cache]):
            with self.assertRaises(ValueError):
                module.normalize({'sourceFileCount': len(entries), 'entries': entries}, self.document)

    def test_changed_python_source_rejected(self):
        full = copy.deepcopy(self.full)
        full['entries'][0]['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            module.normalize(full, self.document)

    def test_unrelated_cache_or_source_never_ignored(self):
        extra = {'kind': 'file', 'path': 'build/toolchain/__pycache__/unreviewed.pyc', 'sha256': '0' * 64}
        full = {**self.full, 'sourceFileCount': 3, 'entries': self.full['entries'] + [extra]}
        normalized = module.normalize(full, self.document)
        self.assertIn(extra, normalized['entries'])
        self.assertEqual(normalized['sourceFileCount'], 2)

    def test_timeout_and_decode_failure_are_transaction_errors(self):
        for error in (subprocess.TimeoutExpired('python', 15), UnicodeDecodeError('utf8', b'\xff', 0, 1, 'invalid')):
            with patch.object(module.base, 'safe_relative_regular', return_value=Path('/synthetic')), \
                 patch.object(module.base, 'sha256_file', side_effect=[module.SOURCE_HASH, module.CACHE_HASH]), \
                 patch.object(module.subprocess, 'run', side_effect=error), self.assertRaisesRegex(ValueError, 'could not be completed'):
                module.verify_live(Path('/synthetic'), self.document)

    @unittest.skipUnless(Path('/opt/homebrew/bin/python3.14').exists(), 'actual build interpreter unavailable')
    def test_optimized_environment_does_not_disable_derivation_negative_control(self):
        # Byte hashes are independently checked in production. This fixture
        # deliberately bypasses them to exercise the derivation layer itself.
        original_run = subprocess.run
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / module.SOURCE
            source.parent.mkdir(parents=True)
            source.write_text('value = 7\n')
            cache = root / module.CACHE
            cache.parent.mkdir()
            make = 'import marshal,importlib.util,struct,sys;from pathlib import Path;p=Path(sys.argv[1]);s=(p/"' + module.SOURCE + '");(p/"' + module.CACHE + '").write_bytes(importlib.util.MAGIC_NUMBER+struct.pack("<III",0,int(s.stat().st_mtime),s.stat().st_size)+marshal.dumps(compile(s.read_bytes(),"incorrect-build-root","exec")))'
            original_run(['/opt/homebrew/bin/python3.14', '-I', '-B', '-c', make, str(root)], check=True)
            with patch.dict('os.environ', {'PYTHONOPTIMIZE': '2'}), \
                 patch.object(module.base, 'sha256_file', side_effect=[module.SOURCE_HASH, module.CACHE_HASH]), \
                 patch.object(module.subprocess, 'run', wraps=original_run) as run, self.assertRaisesRegex(ValueError, 'fresh source compilation'):
                module.verify_live(root, self.document)
            self.assertEqual(run.call_args.args[0][1:3], ['-I', '-B'])


if __name__ == '__main__':
    unittest.main()
