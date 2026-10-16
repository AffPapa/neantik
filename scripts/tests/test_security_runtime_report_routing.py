"""Frozen successor report/routing controls; no app or probe execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import chromium_15612_font_report as reports
import chromium_15612_variant as variant


class SecurityRuntimeReportTests(unittest.TestCase):
    def test_old_and_security_report_bytes_have_distinct_immutable_policies(self):
        for prefix in (variant.FONT_PREFIX, variant.SECURITY_PREFIX):
            value, raw = reports.frozen_report(ROOT, prefix=prefix)
            name, digest = reports.report_policy(prefix)
            self.assertEqual(hashlib.sha256(raw).hexdigest(), digest)
            self.assertEqual(raw, (ROOT / 'runtime' / name).read_bytes())
            refreshed = {**value, 'createdAt': '2026-10-16T12:00:00Z'}
            self.assertEqual(reports.preserved_report_bytes(refreshed, ROOT), raw)
        self.assertEqual(reports.SHA256, '534900f801963f79dfc2e0b7fc9c693c4a06c6b06d9bb34392c59526c53df885')
        self.assertNotEqual(reports.SECURITY_SHA256, reports.SHA256)

    def test_crossed_reports_unknown_variant_and_changed_bytes_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'runtime-verification.json'
            for prefix in (variant.FONT_PREFIX, variant.SECURITY_PREFIX):
                value, raw = reports.frozen_report(ROOT, prefix=prefix)
                target.write_bytes(raw)
                reports.verify_report_file(target, prefix=prefix)
                other = variant.SECURITY_PREFIX if prefix == variant.FONT_PREFIX else variant.FONT_PREFIX
                with self.assertRaises(ValueError):
                    reports.verify_report_file(target, prefix=other)
                target.write_bytes(raw + b' ')
                with self.assertRaises(ValueError):
                    reports.verify_report_file(target, prefix=prefix)
                broken = {**value, 'sourceVariant': 'font-system-unknown'}
                with self.assertRaises(ValueError):
                    reports.preserved_report_bytes(broken, ROOT)
        for prefix in ('chromium-15612', '', None, '../' + variant.SECURITY_PREFIX):
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                reports.report_policy(prefix)

    def test_security_report_is_bound_to_actual_new_source_and_signed_runtime(self):
        value, _ = reports.frozen_report(ROOT, prefix=variant.SECURITY_PREFIX)
        runtime = ROOT / 'runtime'
        proof = json.loads((runtime / (variant.SECURITY_PREFIX + '-source-proof.json')).read_text())
        self.assertEqual(value['sourceVariant'], variant.SECURITY_VARIANT)
        self.assertEqual(value['sourceDeltaProofSHA256'], hashlib.sha256(
            (runtime / (variant.SECURITY_PREFIX + '-source-proof.json')).read_bytes()).hexdigest())
        self.assertEqual(value['executable']['sha256'], proof['signing']['signedCodeClosure'][value['executable']['path']])
        self.assertEqual(value['framework']['sha256'], proof['signing']['signedCodeClosure'][value['framework']['path']])
        self.assertEqual(value['postbuildFullFDObservationSHA256'], proof['postbuildObservation']['receiptSHA256'])
        self.assertEqual(value['sourceEvidenceMode'],
                         'executed-security-backport-preserved-build-and-postbuild-fd-source-proof')
        self.assertIs(value['freshWholeSourceTreeObserved'], False)
        for key in ('sourceVariant', 'sourceDeltaProofSHA256', 'sourceLockSHA256',
                    'sourceEvidenceMode', 'executable', 'framework'):
            broken = copy.deepcopy(value)
            broken[key] = {} if isinstance(value[key], dict) else 'wrong'
            with self.subTest(key=key), self.assertRaises(ValueError):
                reports.preserved_report_bytes(broken, ROOT)

    def test_security_historical_baseline_survives_later_release_review(self):
        value, raw = reports.frozen_report(ROOT, prefix=variant.SECURITY_PREFIX)
        baseline = reports.historical_baseline(ROOT, prefix=variant.SECURITY_PREFIX)
        self.assertEqual(hashlib.sha256(baseline.read_bytes()).hexdigest(), value['securityBaselineSHA256'])
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            runtime = project / 'runtime'
            archives = runtime / 'security-baselines'
            archives.mkdir(parents=True)
            (runtime / reports.SECURITY_NAME).write_bytes(raw)
            (runtime / 'security-baseline.json').write_text('{"laterReview":true}')
            frozen = archives / (value['securityBaselineSHA256'] + '.json')
            frozen.write_bytes(baseline.read_bytes())
            self.assertEqual(reports.historical_baseline(project, prefix=variant.SECURITY_PREFIX), frozen)
            frozen.write_text('{}')
            with self.assertRaises(ValueError):
                reports.historical_baseline(project, prefix=variant.SECURITY_PREFIX)

    def test_notices_count_security_and_font_layers_separately(self):
        spec = importlib.util.spec_from_file_location('security_notices', ROOT / 'scripts/generate-runtime-integration-notices.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        text = module.render_m154_notices(project_root=ROOT,
            runtime_lock=ROOT / 'runtime' / ('fingerprint-' + variant.SECURITY_PREFIX + '.lock.json'))
        self.assertIn('Additional independently authored font source layers: `6`', text)
        self.assertIn('Additional upstream Chromium/V8 security backports: `8`', text)
        self.assertIn(variant.SECURITY_VARIANT, text)
        for name in ('CHROMIUM_LICENSE.txt', 'V8_LICENSE.txt'):
            self.assertIn('NeAntikRuntimeEvidence/security-backports-20261015/' + name, text)

    def test_packaged_verifier_requires_complete_closure_for_both_successors(self):
        spec = importlib.util.spec_from_file_location('security_packaged', ROOT / 'scripts/verify-packaged-runtime-report.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            for prefix, marker in ((variant.FONT_PREFIX, variant.FONT_VARIANT),
                                   (variant.SECURITY_PREFIX, variant.SECURITY_VARIANT)):
                lock = {'sourceVariant': marker,
                        'sourceContract': 'runtime/' + prefix + '-source-contract.json',
                        'sourceProvenance': 'runtime/' + prefix + '-port-candidate.json'}
                (evidence / 'fingerprint-chromium.lock.json').write_text(json.dumps(lock))
                # Source/report validation has independent actual-input tests.
                # Isolate this permission boundary so a skipped closure cannot
                # be hidden by an earlier, unrelated validation failure.
                with patch('chromium_15612_packaged_evidence.process'), \
                     patch.object(variant, 'verify_report_source_fields'), \
                     patch.object(variant, 'verify_signed_runtime_identity') as closure:
                    module.verify_m156_source_and_runtime({}, Path('/owned/runtime'), evidence, ROOT)
                    closure.assert_called_once_with(Path('/owned/runtime'), lock, project_root=ROOT)
                    closure.side_effect = ValueError('changed helper/resource with unchanged main hashes')
                    with self.assertRaisesRegex(module.PackagedRuntimeReportError, 'changed helper/resource'):
                        module.verify_m156_source_and_runtime({}, Path('/owned/runtime'), evidence, ROOT)

    def test_shell_syntax_uses_each_declared_interpreter(self):
        for name in ('package-integrated-app.sh', 'verify-built-runtime.sh'):
            file = ROOT / 'scripts' / name
            interpreter = file.read_text().splitlines()[0].removeprefix('#!')
            self.assertIn(interpreter, ('/bin/zsh', '/bin/bash'))
            result = subprocess.run([interpreter, '-n', str(file)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, name + ': ' + result.stderr)


if __name__ == '__main__':
    unittest.main()
