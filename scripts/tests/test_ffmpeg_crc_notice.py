import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ffmpeg_crc_notice as notice


class FFmpegCrcNoticeTests(unittest.TestCase):
    def test_portable_notice_binds_overlay_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, output = Path(temporary) / 'source', Path(temporary) / 'output'
            output.mkdir()
            contract = json.loads((notice.ROOT / 'runtime/chromium-15680-source-contract.json').read_text())
            folder = notice.ROOT / 'runtime/chromium-15680-portable-crc'
            for relative, name in [('libavutil/crc.c', 'base-crc.c'),
                                   ('ffmpeg_generated.gni', 'base-ffmpeg_generated.gni'),
                                   ('chromium/config/Chrome/mac/arm64/config.h', 'config.h')]:
                target = source / 'third_party/ffmpeg' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(folder / name, target)
            payload = b'synthetic license text'
            (source / 'third_party/ffmpeg/COPYING.LGPLv2.1').write_bytes(payload)
            lock = {'ownedInputs': {'portableCrcManifestSHA256': contract['portableCRC']['sha256']}}
            with patch.object(notice, 'LGPL_SHA256', hashlib.sha256(payload).hexdigest()):
                binding = notice.make(source, output, lock=lock)
                self.assertEqual(binding['mode'], 'portable-crc')
                self.assertFalse((output / 'ffmpeg-crc.S').exists())
                notice.verify(output, binding, lock=lock)
                (output / 'ffmpeg-crc-portable.c').write_text('modified')
                with self.assertRaisesRegex(ValueError, 'missing or changed'):
                    notice.verify(output, binding, lock=lock)

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
