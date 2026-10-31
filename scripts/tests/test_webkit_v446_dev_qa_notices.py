import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'webkit_runtime_notices.py'
SPEC = importlib.util.spec_from_file_location('v446_notice_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrivateV446DevQANoticeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / 'NeAntik.app'
        self.info = self.app / 'Contents/Info.plist'
        self.info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'app.neantik.desktop.dev'}))
        self.runtime = self.root / 'Frameworks'; self.runtime.mkdir()
        self.paths = {name: self.root / name for name in ('offer', 'source', 'baseline', 'modified', 'binding')}
        self.result = {'status': 'private-v446-evidence-pass', 'releaseQualified': False,
                       'offerManifestSHA256': '988f05c617ac7ddf460c37ac5de3537f2fb7b5bc60cf0dbfa634aed951f63faf',
                       'bindingSHA256': 'af956997d6c3b1f87514899dfc9a164e698cecae583942dfa0d1a83d0b07673d',
                       'imageCount': 16}

    def run_action(self):
        return MODULE.private_v446_dev_qa_notices('preflight', self.app, self.runtime,
                source_offer_root=self.paths['offer'], source=self.paths['source'], baseline=self.paths['baseline'],
                modified=self.paths['modified'], binding=self.paths['binding'])

    def test_dev_only_after_exact_validation_and_context_resets(self):
        def preflight(*args, **kwargs):
            self.assertTrue(MODULE._CURRENT_PRIVATE_V446_QA.get())
            self.assertEqual(kwargs['source_offer_manifest_sha256'], self.result['offerManifestSHA256'])
            return 'checked'
        with mock.patch.object(MODULE, '_verify_private_v446_evidence', return_value=self.result) as validate, \
             mock.patch.object(MODULE, 'preflight_owned_webkit_notices', side_effect=preflight):
            self.assertEqual(self.run_action(), 'checked')
            validate.assert_called_once()
        self.assertFalse(MODULE._CURRENT_PRIVATE_V446_QA.get())

    def test_exact_v508_binding_is_accepted_only_after_validation(self):
        v508 = {**self.result, 'bindingSHA256': 'c4264d49e80670c09cf769f4031fae9740cbc1accfa5d37372b78d270b0df39a'}
        with mock.patch.object(MODULE, '_verify_private_v446_evidence', return_value=v508), \
             mock.patch.object(MODULE, 'preflight_owned_webkit_notices', return_value='checked'):
            self.assertEqual(self.run_action(), 'checked')
        self.assertFalse(MODULE._CURRENT_PRIVATE_V446_QA.get())

    def test_production_identity_rejected_before_evidence_or_notice_action(self):
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'app.neantik.desktop'}))
        with mock.patch.object(MODULE, '_verify_private_v446_evidence') as validate, \
             mock.patch.object(MODULE, 'preflight_owned_webkit_notices') as preflight:
            with self.assertRaisesRegex(MODULE.NoticeError, 'separate Dev bundle identity'): self.run_action()
            validate.assert_not_called(); preflight.assert_not_called()
        self.assertFalse(MODULE._CURRENT_PRIVATE_V446_QA.get())

    def test_untrusted_or_failed_evidence_does_not_enable_qa(self):
        for result in ({**self.result, 'bindingSHA256': '0' * 64},
                       {**self.result, 'releaseQualified': True}, {'status': 'pass'}):
            with mock.patch.object(MODULE, '_verify_private_v446_evidence', return_value=result), \
                 mock.patch.object(MODULE, 'preflight_owned_webkit_notices') as preflight:
                with self.assertRaisesRegex(MODULE.NoticeError, 'evidence identity mismatch'): self.run_action()
                preflight.assert_not_called()
                self.assertFalse(MODULE._CURRENT_PRIVATE_V446_QA.get())
        with mock.patch.object(MODULE, '_verify_private_v446_evidence', side_effect=MODULE.NoticeError('failed')):
            with self.assertRaises(MODULE.NoticeError): self.run_action()
        self.assertFalse(MODULE._CURRENT_PRIVATE_V446_QA.get())

    def test_failed_qa_notice_preflight_resets_context(self):
        with mock.patch.object(MODULE, '_verify_private_v446_evidence', return_value=self.result), \
             mock.patch.object(MODULE, 'preflight_owned_webkit_notices', side_effect=MODULE.NoticeError('overlay mismatch')):
            with self.assertRaisesRegex(MODULE.NoticeError, 'overlay mismatch'): self.run_action()
        self.assertFalse(MODULE._CURRENT_PRIVATE_V446_QA.get())

    def test_only_exact_offer_gets_one_gpu_override_and_default_stays_pinned(self):
        gpu = MODULE.WEBGPU_IMAGE_PATH.as_posix()
        original = MODULE.RuntimeHashBindings({gpu: 'a' * 64, 'other': 'b' * 64}, signed_image_hashes={gpu: 'c' * 64})
        @MODULE._with_v382_runtime_hashes
        def sample(app, runtime_frameworks=None, *, project_root=MODULE.PROJECT_ROOT, source_offer_root=None):
            return dict(MODULE._CURRENT_V382_RUNTIME_HASHES.get())
        with mock.patch.object(MODULE, '_v382_runtime_hashes', return_value=original):
            self.assertEqual(sample(self.app, source_offer_manifest_sha256=self.result['offerManifestSHA256'])[gpu], 'a' * 64)
            token = MODULE._CURRENT_PRIVATE_V446_QA.set(True)
            try:
                current = sample(self.app, source_offer_manifest_sha256=self.result['offerManifestSHA256'])
                self.assertEqual(current[gpu], 'fd292af52b1011541c6bed02c010cdada4c51d2f115ffc0ce334dd679ae4daac')
                self.assertEqual(current['other'], 'b' * 64)
                with self.assertRaisesRegex(MODULE.NoticeError, 'exact V465 offer'):
                    sample(self.app, source_offer_manifest_sha256='0' * 64)
            finally: MODULE._CURRENT_PRIVATE_V446_QA.reset(token)
        self.assertEqual(original[gpu], 'a' * 64)
        self.assertIsNone(MODULE._CURRENT_V382_RUNTIME_HASHES.get())
