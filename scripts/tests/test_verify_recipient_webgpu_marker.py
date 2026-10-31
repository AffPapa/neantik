import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-recipient-webgpu-marker.py'
SPEC = importlib.util.spec_from_file_location('recipient_webgpu_marker_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RecipientWebGPUMarkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.source, self.image, self.patch = root / 'original', root / 'image', root / 'change.patch'
        self.source.write_bytes(b'original\n')
        self.image.write_bytes(b'MachO-marker')
        self.patch.write_bytes(b'--- a/Source/WebGPU/WebGPU/Adapter.mm\n+++ b/Source/WebGPU/WebGPU/Adapter.mm\n@@ -1 +1,2 @@\n original\n+marker\n')
        sha = lambda x: hashlib.sha256(x).hexdigest()
        constants = {'SOURCE_SHA': sha(self.source.read_bytes()), 'IMAGE_SHA': sha(self.image.read_bytes()),
                     'PATCH_SHA': sha(self.patch.read_bytes()), 'MODIFIED_SHA': sha(b'original\nmarker\n'),
                     'MARKER': b'marker'}
        self.patcher = mock.patch.multiple(MODULE, **constants)
        self.patcher.start(); self.addCleanup(self.patcher.stop)

    def test_replay_and_marker_do_not_claim_release(self):
        result = MODULE.verify(self.source, self.image, self.patch)
        self.assertEqual(result['status'], 'local-marker-replay-and-image-pass')
        self.assertFalse(result['releaseQualified'])

    def test_altered_source_patch_or_image_are_refused(self):
        for path in (self.source, self.patch, self.image):
            original = path.read_bytes(); path.write_bytes(original + b'tamper')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                MODULE.verify(self.source, self.image, self.patch)
            path.write_bytes(original)

    def test_symlink_inputs_refused(self):
        link = Path(self.tmp.name) / 'link'; link.symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, 'physical files'):
            MODULE.verify(link, self.image, self.patch)
