"""Compiled whole-pair selection and immutable report controls; no native QA."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import chromium_15612_font_report as report
spec = importlib.util.spec_from_file_location('runtime_pair_checker', ROOT / 'scripts/verify-direct-update-runtime-pins.py')
pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pins)


class FontRuntimeBindingTests(unittest.TestCase):
    def test_complete_compiled_records_not_first_digest_or_cross_product(self):
        records = pins.compiled_records(ROOT)
        self.assertEqual([r['name'] for r in records], ['final9', 'font-system-v1', 'font-system-security-20261015-v1', 'component-completion-v1', 'privacy-policy-v1'])
        for runtime in records:
            for evidence in records:
                for raw_report in records:
                    observed = {'runtime': runtime['runtime'], 'evidence': evidence['evidence']}
                    if runtime == evidence == raw_report:
                        self.assertEqual(pins.select_record(observed, raw_report['reportDigest'], records), runtime['name'])
                    else:
                        with self.assertRaisesRegex(ValueError, 'complete compiled record'):
                            pins.select_record(observed, raw_report['reportDigest'], records)
        for record in records:
            observed = {scope: record[scope] for scope in ('runtime', 'evidence')}
            for scope in observed:
                for key in ('digest', 'entries', 'bytes', 'machoCount'):
                    bad = copy.deepcopy(observed)
                    bad[scope][key] = 'wrong' if key == 'digest' else bad[scope][key] + 1
                    with self.assertRaises(ValueError):
                        pins.select_record(bad, record['reportDigest'], records)
            with self.assertRaises(ValueError):
                pins.select_record(observed, record['reportDigest'], records + [record])

    def test_frozen_report_preserves_creation_date_only_for_identical_inputs(self):
        value, raw = report.frozen_report(ROOT)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), report.SHA256)
        changed = {**value, 'createdAt': '2026-10-16T01:00:00Z'}
        self.assertEqual(report.preserved_report_bytes(changed, ROOT), raw)
        controls = {'machoCount': 15, 'sourceVariant': 'font-system-v2',
                    'createdAt': 'invalid', 'sourceLockSHA256': '0' * 64, 'executable': {}}
        for key, replacement in controls.items():
            bad = copy.deepcopy(value); bad[key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                report.preserved_report_bytes(bad, ROOT)
        for key in value:
            bad = copy.deepcopy(value); bad.pop(key)
            with self.subTest(missing=key), self.assertRaises(ValueError):
                report.preserved_report_bytes(bad, ROOT)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'report.json';path.write_bytes(raw)
            report.verify_report_file(path)
            path.write_bytes(raw + b' ')
            with self.assertRaisesRegex(ValueError, 'compiled binding'):
                report.verify_report_file(path)

    def test_legacy_record_and_report_remain_exact(self):
        record = pins.compiled_records(ROOT)[0]
        raw = (ROOT / 'Tests/Fixtures/direct-update-final9-runtime-verification.json').read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), record['reportDigest'])
        self.assertEqual(record['runtime']['digest'], '176c65a1e1e069dcc36ef56ab6210753db7fc23527efc5bfbcb4afc5714a6efe')
        self.assertEqual(record['evidence']['digest'], 'fdd445c8f874b0b69c860e48ced8ba87c8f333744e53830d16cbf16e671bcb1c')
        new, _ = report.frozen_report(ROOT)
        self.assertNotIn('sourceVariant', json.loads(raw))
        self.assertNotIn('fullFDObservationSHA256', new)

class FontPackagingReproducibilityTests(unittest.TestCase):
    def test_archived_baseline_survives_current_baseline_refresh(self):
        value, raw = report.frozen_report(ROOT)
        digest = value['securityBaselineSHA256']
        archived = ROOT / 'runtime/security-baselines' / (digest + '.json')
        self.assertEqual(hashlib.sha256(archived.read_bytes()).hexdigest(), digest)
        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder);runtime = project / 'runtime';runtime.mkdir()
            (runtime / report.NAME).write_bytes(raw)
            (runtime / 'security-baselines').mkdir()
            target = runtime / 'security-baselines' / archived.name
            target.write_bytes(archived.read_bytes())
            (runtime / 'security-baseline.json').write_text('{"newPublicationObservation":true}')
            self.assertEqual(report.historical_baseline(project), target)
            target.write_text('{}')
            with self.assertRaises(ValueError):
                report.historical_baseline(project)

    def test_actual_source_copy_under_restrictive_umask_has_deterministic_modes(self):
        import os
        import stat
        import chromium_15612_packaged_evidence as packaged
        from chromium_15612_variant import FONT_PREFIX
        lock = json.loads((ROOT / 'runtime' / ('fingerprint-' + FONT_PREFIX + '.lock.json')).read_text())
        with tempfile.TemporaryDirectory() as folder:
            old_mask = os.umask(0o077)
            try:
                evidence = Path(folder) / 'evidence';evidence.mkdir()
                packaged.process(ROOT, evidence, lock, copy=True)
                common = {'fingerprint-chromium.lock.json': json.dumps(lock).encode(),
                          'source-provenance.json': (ROOT / 'runtime' / (FONT_PREFIX + '-port-candidate.json')).read_bytes(),
                          'runtime-verification.json': report.frozen_report(ROOT)[1],
                          'security-baseline.json': report.historical_baseline(ROOT).read_bytes(),
                          'release-security-baseline.json': (ROOT / 'runtime/security-baseline.json').read_bytes(),
                          'neantik-patch-series.json': (ROOT / 'runtime/nevision-patches/series.json').read_bytes(),
                          'apple-device-tuples.json': (ROOT / 'runtime/apple-device-tuples.json').read_bytes(),
                          'args.gn': b'owned mode fixture; not a runtime qualification\n'}
                for name, raw in common.items():
                    (evidence / name).write_bytes(raw)
            finally:
                os.umask(old_mask)
            before = {p.relative_to(evidence).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in evidence.rglob('*') if p.is_file()}
            self.assertEqual(stat.S_IMODE(evidence.stat().st_mode), 0o700)
            packaged.normalize_font_modes(ROOT, evidence, lock)
            self.assertEqual(stat.S_IMODE(evidence.stat().st_mode), 0o755)
            for path in evidence.rglob('*'):
                name = path.relative_to(evidence).as_posix()
                expected = 0o755 if path.is_dir() else 0o600 if name in {'runtime-verification.json', 'release-security-baseline.json'} else 0o644
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), expected)
            after = {p.relative_to(evidence).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in evidence.rglob('*') if p.is_file()}
            self.assertEqual(before, after)


if __name__ == '__main__':
    unittest.main()
