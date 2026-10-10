import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import chromium_15612_python311_cache as helper
from chromium_15612_generated_cache import M156CacheError
from test_chromium_15612_generated_cache import file, snapshot


class Python311CacheTests(unittest.TestCase):
    def test_explicit_new_311_and_314_only(self):
        source = file('tools/owned.py')
        before = snapshot([source])
        after = snapshot([source, file('tools/__pycache__/owned.cpython-311.pyc')])
        result = helper.compare_observed_target_caches(before, after)
        self.assertEqual(len(result['cpython311']), 1)
        self.assertEqual(result['cpython314'], [])
        for minor in ['310', '312', '313', '315']:
            wrong = snapshot([source, file('tools/__pycache__/owned.cpython-'+minor+'.pyc')])
            with self.assertRaises(M156CacheError): helper.compare_observed_target_caches(before, wrong)

    def test_changed_source_permissions_deletion_and_existing_311_rejected(self):
        source = file('tools/owned.py')
        cache = file('tools/__pycache__/owned.cpython-311.pyc')
        before, after = snapshot([source]), snapshot([source, cache])
        for patch in [{'mode': 0o666}, {'sizeBytes': 4*1024*1024+1}]:
            wrong = snapshot([source, {**cache, **patch}])
            with self.assertRaises(M156CacheError): helper.compare_observed_target_caches(before, wrong)
        wrong = snapshot([file(source['path'], 'b'*64), cache])
        with self.assertRaises(M156CacheError): helper.compare_observed_target_caches(before, wrong)
        with self.assertRaises(M156CacheError): helper.compare_observed_target_caches(after, before)
        wrong = snapshot([source, {**cache, 'sha256': 'b'*64}])
        with self.assertRaises(M156CacheError): helper.compare_observed_target_caches(after, wrong)

    @unittest.skipUnless(helper.PYTHON311.exists(), 'Observed CPython3.11 unavailable')
    def test_actual_cache_and_rebound_tamper_controls_never_execute_source(self):
        with tempfile.TemporaryDirectory(prefix='neantik311-cache-') as temp:
            root = Path(temp); (root/'tools').mkdir()
            source = root/'tools/owned.py'; sentinel = root/'no-source-execution'
            source.write_text('from pathlib import Path\nPath('+repr(str(sentinel))+').write_text("executed")\nvalue=-0.0\ndef operation(x):\n return x+7\n')
            result = subprocess.run([str(helper.PYTHON311), '-I', '-S', '-B', '-c',
                'import py_compile,sys;py_compile.compile(sys.argv[1],doraise=True)', str(source)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            cache = root/'tools/__pycache__/owned.cpython-311.pyc'; original = cache.read_bytes()
            sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
            record = lambda: {'cache': str(cache.relative_to(root)), 'source': str(source.relative_to(root)),
                'cacheSHA256': sha(cache), 'sourceSHA256': sha(source), 'cacheBytes': cache.stat().st_size}
            helper.verify311(root, record()); self.assertFalse(sentinel.exists())
            for wrong in [original+b'append', bytes(16)+original[16:]]:
                cache.write_bytes(wrong)
                with self.assertRaises(M156CacheError): helper.verify311(root, record())
            cache.write_bytes(original)
            saved = record(); source.write_text('raise SystemExit("do not run")\n')
            with self.assertRaises(M156CacheError): helper.verify311(root, saved)
            with self.assertRaises(M156CacheError): helper.verify311(root, record(), Path('/usr/bin/python3'))
            self.assertFalse(sentinel.exists())

if __name__ == '__main__': unittest.main()
