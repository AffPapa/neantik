import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ffmpeg_crc_notice as notice


class FFmpegCrcNoticeTests(unittest.TestCase):
    def test_source_binding_and_tamper_refusal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / 'source', root / 'output'
            source.mkdir(); output.mkdir()
            payload = b'synthetic source'
            (source / 'input').write_bytes(payload)
            files = {'crc.S': ('input', hashlib.sha256(payload).hexdigest())}
            with patch.object(notice, 'FILES', files):
                binding = notice.make(source, output)
                notice.verify(output, binding)
                (output / 'crc.S').write_bytes(b'modified')
                with self.assertRaisesRegex(ValueError, 'missing or changed'):
                    notice.verify(output, binding)
                (source / 'input').write_bytes(b'modified')
                with self.assertRaisesRegex(ValueError, 'input hash'):
                    notice.make(source, output)

    def test_missing_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, 'manifest mismatch'):
                notice.verify(Path(temporary), None)
