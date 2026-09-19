import copy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from owned_antifraud_metrics import rate, summarize, unique_object


def fixture():
    return {'schemaVersion': 1, 'mode': 'shadow', 'partition': 'evaluation',
            'unit': 'independent-synthetic-profile', 'labelSource': 'independent-scenario-oracle',
            'rows': [{'cohort': 'vpn', 'automation': 'automated', 'truth': 'legitimate', 'decision': 'block', 'count': 1},
                     {'cohort': 'vpn', 'automation': 'manual', 'truth': 'legitimate', 'decision': 'allow', 'count': 9}],
            'identity': {'falseMerge': 1, 'distinctPairs': 20, 'falseSplit': 0, 'samePairs': 10}}


class OwnedAntifraudMetricsTests(unittest.TestCase):
    def test_cli_requires_opt_in_and_never_echoes_rejected_private_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'study.json'
            path.write_text(json.dumps(fixture()))
            command = [sys.executable, str(Path(__file__).resolve().parents[1] / 'owned_antifraud_metrics.py'), str(path)]
            missing = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            valid = subprocess.run([*command, '--acknowledge-owned-study'], capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertEqual(json.loads(valid.stdout)['enforcement'], 'none')
            data = fixture(); data['cookie'] = 'SYNTHETIC_PRIVATE_CANARY'
            path.write_text(json.dumps(data))
            invalid = subprocess.run([*command, '--acknowledge-owned-study'], capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertNotIn('SYNTHETIC_PRIVATE_CANARY', invalid.stdout + invalid.stderr)

    def test_separates_cohorts_automation_identity_and_fraud(self):
        result = summarize(fixture())
        self.assertEqual(result['cohorts']['vpn']['falseBlock']['rate'], .1)
        self.assertIsNone(result['cohorts']['privacy']['falseBlock']['rate'])
        self.assertIsNone(result['cohorts']['vpn']['missedIntervention']['rate'])
        self.assertEqual(result['identity']['falseMerge']['rate'], .05)
        self.assertEqual(result['automationCountsNotFraudLabels'], {'manual': 9, 'automated': 1})
        self.assertEqual(result['enforcement'], 'none')

    def test_intervals_include_uncertainty_at_zero_and_one(self):
        self.assertGreater(rate(0, 10)['wilson95'][1], 0)
        self.assertLess(rate(10, 10)['wilson95'][0], 1)
        self.assertIsNone(rate(0, 0)['wilson95'])

    def test_rejects_private_fields_training_mixture_and_unbounded_counts(self):
        for key, value in [('mode', 'enforce'), ('partition', 'training'), ('unit', 'reload'), ('labelSource', 'fingerprint'), ('token', 'SYNTHETIC_PRIVATE')]:
            data = fixture(); data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): summarize(data)
        for value in (-1, True, 1.5, 1_000_001):
            data = fixture(); data['rows'][0]['count'] = value
            with self.subTest(value=value), self.assertRaises(ValueError): summarize(data)

    def test_rejects_duplicate_cells_and_impossible_identity_rates(self):
        data = fixture(); data['rows'].append(copy.deepcopy(data['rows'][0]))
        with self.assertRaises(ValueError): summarize(data)
        data = fixture(); data['identity']['falseMerge'] = 21
        with self.assertRaises(ValueError): summarize(data)
        with self.assertRaises(ValueError): json.loads('{"mode":"shadow","mode":"enforce"}', object_pairs_hook=unique_object)
