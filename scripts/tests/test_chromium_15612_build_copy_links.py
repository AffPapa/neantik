import hashlib
import os
from pathlib import Path
import tempfile
import unittest
import chromium_15612_build_copy_links as helper
from chromium_15612_generated_cache import M156CacheError


class NativeCopyLinkTests(unittest.TestCase):
    def test_owned_copy_and_unknown_extra_alias_refusal(self):
        with tempfile.TemporaryDirectory(prefix='neantik-copy-links-') as temp:
            root = Path(temp).resolve(); source = root/'owned.py'; source.write_bytes(b'value=7\n')
            output = root/helper.OUTPUT_PREFIX; output.mkdir(parents=True)
            alias = output/'owned.py'; os.link(source, alias)
            info = source.stat()
            record = {'path': 'owned.py', 'links': info.st_nlink, 'device': info.st_dev,
                      'inode': info.st_ino, 'mode': 0o644, 'sizeBytes': info.st_size,
                      'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                      'outputAliases': [alias.relative_to(root).as_posix()]}
            self.assertEqual(helper.read_known_copy_source(root, 'owned.py', 100, record)[0], b'value=7\n')
            for wrong in [{**record, 'sha256': 'a'*64}, {**record, 'outputAliases': ['../outside']},
                          {**record, 'outputAliases': ['other/owned.py']}, {**record, 'links': True}]:
                with self.assertRaises((M156CacheError, OSError)):
                    helper.read_known_copy_source(root, 'owned.py', 100, wrong)
            os.link(source, root/'unlisted-alias')
            with self.assertRaises(M156CacheError): helper.read_known_copy_source(root, 'owned.py', 100, record)

    def test_replaced_alias_and_symlink_are_not_accepted(self):
        with tempfile.TemporaryDirectory(prefix='neantik-copy-links-') as temp:
            root = Path(temp).resolve(); source = root/'owned.py'; source.write_bytes(b'value=7\n')
            output = root/helper.OUTPUT_PREFIX; output.mkdir(parents=True)
            alias = output/'owned.py'; os.link(source, alias)
            info = source.stat()
            record = {'path': 'owned.py', 'links': 2, 'device': info.st_dev,
                      'inode': info.st_ino, 'mode': 0o644, 'sizeBytes': info.st_size,
                      'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                      'outputAliases': [alias.relative_to(root).as_posix()]}
            alias.unlink(); alias.symlink_to(source)
            with self.assertRaises((M156CacheError, OSError)):
                helper.read_known_copy_source(root, 'owned.py', 100, record)
            alias.unlink(); alias.write_bytes(source.read_bytes())
            with self.assertRaises(M156CacheError): helper.read_known_copy_source(root, 'owned.py', 100, record)

if __name__ == '__main__': unittest.main()
