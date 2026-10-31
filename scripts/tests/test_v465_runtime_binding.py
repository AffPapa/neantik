import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'webkit_runtime_notices.py'
SPEC = importlib.util.spec_from_file_location('v465_runtime_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PROJECT = SCRIPT.parents[1]

class RuntimeBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.offer = self.root / 'offer'; self.offer.mkdir()
        self.project = self.root / 'project'; self.project.mkdir()
        source = PROJECT / MODULE.V465_LOCAL_BINDING_PATH
        self.component = self.offer / MODULE.V465_RUNTIME_BINDING_PATH
        self.component.parent.mkdir(parents=True)
        shutil.copyfile(source, self.component)
        local = self.project / MODULE.V465_LOCAL_BINDING_PATH
        local.parent.mkdir(parents=True)
        shutil.copyfile(source, local)
        data = json.loads(source.read_text())
        self.paths = {r['path'] for r in data['stageAndSignedImages']}
        self.manifest = {'currentWebKitV465BaselineRuntime': {
            'path': MODULE.V465_RUNTIME_BINDING_PATH.as_posix(),
            'sha256': MODULE.V465_RUNTIME_BINDING_SHA256},
            'sourceOfferComponents': [{'path': MODULE.V465_RUNTIME_BINDING_PATH.as_posix(),
                'sha256': MODULE.V465_RUNTIME_BINDING_SHA256,
                'bytes': self.component.stat().st_size, 'includedInOfferFolder': True}]}

    def test_exact_identity_and_all_signed_rows(self):
        result = MODULE._v465_runtime_binding(self.project, self.offer, self.manifest, self.paths)
        self.assertEqual(len(result.signed_image_hashes), 16)
        self.assertIn('WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib', result)
        self.assertIn('libswiftCompatibilitySpan.dylib', result)

    def test_tampered_and_symlinked_component_rejected(self):
        self.component.write_text('tampered')
        with self.assertRaises((ValueError, MODULE.NoticeError)):
            MODULE._v465_runtime_binding(self.project, self.offer, self.manifest, self.paths)
        self.component.unlink()
        self.component.symlink_to(PROJECT / MODULE.V465_LOCAL_BINDING_PATH)
        with self.assertRaises((ValueError, MODULE.NoticeError)):
            MODULE._v465_runtime_binding(self.project, self.offer, self.manifest, self.paths)

    def test_duplicate_missing_or_incorrect_inventory_rejected(self):
        self.manifest['sourceOfferComponents'].append(self.manifest['sourceOfferComponents'][0])
        with self.assertRaises(ValueError):
            MODULE._v465_runtime_binding(self.project, self.offer, self.manifest, self.paths)
        self.manifest['sourceOfferComponents'].pop()
        with self.assertRaises(ValueError):
            MODULE._v465_runtime_binding(self.project, self.offer, self.manifest, set())

class StabilizedRuntimeBindingTests(unittest.TestCase):
    def test_stabilized_identity_and_variant_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); project = root / 'project'; offer = root / 'offer'
            local = project / MODULE.V467_LOCAL_BINDING_PATH
            component = offer / MODULE.V467_RUNTIME_BINDING_PATH
            local.parent.mkdir(parents=True); component.parent.mkdir(parents=True)
            source = PROJECT / MODULE.V467_LOCAL_BINDING_PATH
            shutil.copyfile(source, local); shutil.copyfile(source, component)
            data = json.loads(source.read_text())
            paths = {row['path'] for row in data['stageAndSignedImages']}
            row = {'path': MODULE.V467_RUNTIME_BINDING_PATH.as_posix(),
                   'sha256': MODULE.V467_RUNTIME_BINDING_SHA256,
                   'bytes': component.stat().st_size, 'includedInOfferFolder': True}
            manifest = {'currentWebKitV467StabilizedRuntime':
                        {'path': row['path'], 'sha256': row['sha256']},
                        'sourceOfferComponents': [row]}
            result = MODULE._v465_runtime_binding(project, offer, manifest, paths, stabilized=True)
            self.assertEqual(len(result.signed_image_hashes), 16)
            self.assertEqual(result['WebCore.framework/Versions/A/WebCore'],
                             'b601d9580b268ce621a154d792b809e135f1240048de873ee04fc248ec3e8e33')
            with self.assertRaises((KeyError, ValueError, MODULE.NoticeError)):
                MODULE._v465_runtime_binding(project, offer, manifest, paths)


class NestedDigestTests(unittest.TestCase):
    def test_nested_verification_keeps_explicit_digest_and_resets_context(self):
        seen = []
        def fake(_project, _root, digest=None):
            seen.append(digest)
            return MODULE.RuntimeHashBindings({})
        @MODULE._with_v382_runtime_hashes
        def inner(app, runtime_frameworks=None, *, project_root=PROJECT, source_offer_root=None):
            return 'ok'
        @MODULE._with_v382_runtime_hashes
        def outer(app, runtime_frameworks=None, *, project_root=PROJECT, source_offer_root=None):
            return inner(app, runtime_frameworks, project_root=project_root, source_offer_root=source_offer_root)
        with mock.patch.object(MODULE, '_v382_runtime_hashes', side_effect=fake):
            self.assertEqual(outer(Path('/tmp/a'), source_offer_root=Path('/tmp/b'),
                                   source_offer_manifest_sha256='a' * 64), 'ok')
        self.assertEqual(seen, ['a' * 64, 'a' * 64])
        self.assertIsNone(MODULE._CURRENT_SOURCE_OFFER_DIGEST.get())


if __name__ == '__main__':
    unittest.main()
