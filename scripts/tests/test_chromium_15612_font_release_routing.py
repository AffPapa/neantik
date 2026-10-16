"""Actual source/package admission plus sensitive routing controls; no native QA."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import chromium_15612_variant as variant
import chromium_15612_packaged_evidence as packaged
from runtime_build_path import verify_build_args
from runtime_candidate_lock import expected_candidate_lock
from runtime_source_provenance import verify_document, verify_runtime_lock_for_new_candidate, verify_contract


def module(name):
    spec = importlib.util.spec_from_file_location('font_routing_' + name.replace('-', '_'), SCRIPTS / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = value
    spec.loader.exec_module(value)
    return value


class FontReleaseRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock_path = ROOT / 'runtime' / ('fingerprint-' + variant.FONT_PREFIX + '.lock.json')
        cls.candidate_path = ROOT / 'runtime' / (variant.FONT_PREFIX + '-port-candidate.json')
        cls.lock = json.loads(cls.lock_path.read_text())
        cls.candidate = json.loads(cls.candidate_path.read_text())

    def test_actual_generic_source_entrypoints_select_successor_and_reject_stripped_marker(self):
        verify_document(self.candidate, project_root=ROOT)
        self.assertEqual(expected_candidate_lock(self.candidate_path, project_root=ROOT), self.lock)
        verify_runtime_lock_for_new_candidate(self.lock_path, project_root=ROOT)
        contract = verify_contract(project_root=ROOT,
            contract_path=ROOT / 'runtime' / (variant.FONT_PREFIX + '-source-contract.json'),
            rebase_plan_path=ROOT / 'runtime/chromium-15612-rebase-plan.json')
        self.assertEqual(contract['sourceVariant'], variant.FONT_VARIANT)
        broken = copy.deepcopy(self.candidate)
        broken.pop('sourceVariant')
        with self.assertRaises(ValueError):
            verify_document(broken, project_root=ROOT)

    def test_actual_source_dependency_copy_and_corruption_refusal(self):
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)
            packaged.process(ROOT, evidence, self.lock, copy=True)
            names = packaged.names(ROOT, self.lock)
            self.assertIn('font-policy-v1/system_font_source_variations.cc', names)
            self.assertIn('font-policy-v1/headed-development.json', names)
            self.assertEqual((evidence / 'font-policy-v1/headed-development.json').read_bytes(),
                             (ROOT / 'docs/evidence/font-variation-headed-development.json').read_bytes())
            self.assertFalse(any('private' in name or name.startswith('/') or '..' in name.split('/') for name in names))
            asset = evidence / 'font-policy-v1/witness/fonts/owned-canary.ttf'
            raw = asset.read_bytes()
            asset.write_bytes(raw + b'changed')
            with self.assertRaisesRegex(ValueError, 'differs'):
                packaged.process(ROOT, evidence, self.lock)
            asset.write_bytes(raw)
            qa = evidence / 'font-policy-v1/native-probe/BUILD.gn'
            qa.unlink()
            qa.symlink_to(ROOT / 'runtime/font-policy-v1/native-probe/BUILD.gn')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                packaged.process(ROOT, evidence, self.lock)
            qa.unlink()
            qa.write_bytes((ROOT / 'runtime/font-policy-v1/native-probe/BUILD.gn').read_bytes())
            (evidence / 'font-policy-v1/unreviewed.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'extra'):
                packaged.process(ROOT, evidence, self.lock)

    def test_report_scope_has_distinct_ancestor_and_postbuild_proofs(self):
        new = variant.report_source_fields(self.lock, project_root=ROOT)
        old_lock = json.loads((ROOT / 'runtime/fingerprint-chromium-15612.lock.json').read_text())
        old = variant.report_source_fields(old_lock, project_root=ROOT)
        self.assertNotIn('fullFDObservationSHA256', new)
        self.assertNotEqual(new['baseFullFDObservationSHA256'], new['postbuildFullFDObservationSHA256'])
        self.assertEqual(new['baseFullFDObservationSHA256'], old['fullFDObservationSHA256'])
        # Authenticate each scope above; exercise field-comparison sensitivity
        # independently, without redoing the expensive source proof per typo.
        for lock, fields in ((self.lock, new), (old_lock, old)):
            with patch.object(variant, 'report_source_fields', return_value=fields):
                variant.verify_report_source_fields({'unrelatedReportField': True, **fields}, lock, project_root=ROOT)
                for key in fields:
                    broken = copy.deepcopy(fields)
                    broken.pop(key)
                    with self.subTest(missing=key), self.assertRaises(ValueError):
                        variant.verify_report_source_fields(broken, lock, project_root=ROOT)
                for other in (old, new):
                    if other == fields:
                        continue
                    with self.assertRaises(ValueError):
                        variant.verify_report_source_fields(other, lock, project_root=ROOT)
                    with self.assertRaises(ValueError):
                        variant.verify_report_source_fields({**fields, **other}, lock, project_root=ROOT)
                for wrong in (True, 0, None):
                    with self.assertRaises(ValueError):
                        variant.verify_report_source_fields({**fields, 'freshWholeSourceTreeObserved': wrong}, lock, project_root=ROOT)

    def test_gui_report_and_candidate_manifest_use_exact_variant_contract(self):
        gui = module('verify-gui-fingerprint-report')
        report = module('verify-packaged-runtime-report')
        self.assertEqual(gui.source_contract_name('156.0.8078.12', self.lock), variant.FONT_PREFIX + '-source-contract.json')
        paths = report.source_evidence_paths('156.0.8078.12', Path('/evidence'), ROOT, self.lock)
        self.assertEqual(paths, (self.lock_path, Path('/evidence') / (variant.FONT_PREFIX + '-source-contract.json')))
        stripped = copy.deepcopy(self.lock)
        stripped.pop('sourceVariant')
        with self.assertRaises(ValueError):
            gui.source_contract_name('156.0.8078.12', stripped)
        fixture_spec = importlib.util.spec_from_file_location('font_manifest_fixture', SCRIPTS / 'tests/test_direct_candidate_manifest.py')
        fixture = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixture)
        with tempfile.TemporaryDirectory() as folder:
            app = fixture.prepared_fixture(Path(folder))
            resources = app / 'Contents/Resources'
            info_path = resources / 'NeAntik Browser.app/Contents/Info.plist'
            with info_path.open('rb') as f:
                info = plistlib.load(f)
            info['CFBundleShortVersionString'] = '156.0.8078.12'
            with info_path.open('wb') as f:
                plistlib.dump(info, f)
            evidence = resources / 'NeAntikRuntimeEvidence'
            (evidence / 'fingerprint-chromium.lock.json').write_text(json.dumps(self.lock))
            destination = evidence / (variant.FONT_PREFIX + '-source-contract.json')
            destination.write_bytes((ROOT / 'runtime' / destination.name).read_bytes())
            manifest = fixture.MODULE.manifest_payload(app, release_channel='public-alpha', fingerprint_evidence=fixture.fingerprint_binding())
            self.assertTrue(manifest['criticalFiles']['sourceContract']['bundlePath'].endswith(destination.name))

    def test_notices_keep_base_counts_separate_from_six_font_layers(self):
        notices = module('generate-runtime-integration-notices')
        text = notices.render_m154_notices(project_root=ROOT, runtime_lock=self.lock_path)
        self.assertIn('`font-system-v1`', text)
        self.assertIn('font source layers: `6`', text)
        self.assertIn('preserved postbuild observation', text)

    def test_build_args_cannot_borrow_legacy_directory_or_plain_copied_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            src = Path(folder) / 'src'
            wrong = src / 'out/NeAntikM156Qualified20261009/args.gn'
            wrong.parent.mkdir(parents=True)
            wrong.write_text('not the selected output')
            with self.assertRaisesRegex(ValueError, 'exact M156 qualified'):
                verify_build_args(src, wrong, self.lock, ROOT)
        source = module('verify-runtime-source-provenance')
        with self.assertRaisesRegex(ValueError, 'postbuild FD proof'):
            source.verify_live_source(self.candidate, Path('/unrelated'), ROOT)

class StandaloneFontReportGateTests(unittest.TestCase):
    def test_packaged_gate_does_not_accept_report_relabeling(self):
        import chromium_15612_source_context as contexts
        verifier = module('verify-packaged-runtime-report')
        lock = json.loads((ROOT / 'runtime/fingerprint-chromium-15612-font-system-v1.lock.json').read_text())
        fields = variant.report_source_fields(lock, project_root=ROOT)
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)
            (evidence / 'fingerprint-chromium.lock.json').write_text(json.dumps(lock))
            # Isolate the gate after source dependency verification. A forged
            # report can claim any actual hashes; the independent closure check
            # still has to inspect the supplied runtime, not trust those fields.
            with patch.object(contexts, 'verify_source_context', side_effect=contexts.SourceContextUnavailable('isolated full path')), \
                 patch.object(packaged, 'process') as source_check, \
                 patch.object(variant, 'verify_signed_runtime_identity', side_effect=ValueError('wrong actual runtime')) as byte_check:
                with self.assertRaisesRegex(verifier.PackagedRuntimeReportError, 'wrong actual runtime'):
                    verifier.verify_m156_source_and_runtime({**fields, 'executable': {'sha256': '0' * 64}},
                                                           Path('/owned-old-runtime'), evidence, ROOT)
                source_check.assert_called_once()
                byte_check.assert_called_once_with(Path('/owned-old-runtime'), lock, project_root=ROOT, source_context=None)


if __name__ == '__main__':
    unittest.main()
