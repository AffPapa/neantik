import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-profile-race-receipt.py'
spec = importlib.util.spec_from_file_location('receipt', SCRIPT)
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)

FENCE = 'deletedProfileCleanupKeepsProcessFenceThroughCallback'
MARKER = 'markerRemovalFailureIsReportedAfterCommittedDeletionAndPrunesOrganization'
BASE = f'''◇ Test case passing 1 argument failLegacy → false to {FENCE}(failLegacy:) started.
◇ Test case passing 1 argument failLegacy → true to {FENCE}(failLegacy:) started.
✔ Test {FENCE}(failLegacy:) with 2 test cases passed after 0.05 seconds.
✔ Test {MARKER}() passed after 0.02 seconds.
➜ Test unrelatedSlowBenchmark() skipped: limited capacity.
'''


class ProfileRaceReceiptTests(unittest.TestCase):
    def test_passed_tests_and_both_cases_are_confirmed_despite_unrelated_skip(self):
        r = receipt.evaluate(BASE)
        self.assertEqual(r['status'], 'pass')
        self.assertTrue(r['bothCasesVerified'])
        self.assertEqual(r['targetSkipCount'], 0)

    def test_missing_and_skipped_target_are_incomplete(self):
        self.assertEqual(receipt.evaluate(BASE.replace(f'✔ Test {MARKER}() passed after 0.02 seconds.', ''))['status'], 'incomplete')
        skip = BASE + f'➜ Test {MARKER}() skipped: synthetic reason.\n'
        self.assertEqual(receipt.evaluate(skip)['status'], 'incomplete')

    def test_target_failure_and_duplicate_pass_are_incomplete(self):
        self.assertEqual(receipt.evaluate(BASE + f'✘ Test {MARKER}() failed after 0.01 seconds.\n')['status'], 'incomplete')
        self.assertEqual(receipt.evaluate(BASE + f'✔ Test {MARKER}() passed after 0.01 seconds.\n')['status'], 'incomplete')

    def test_both_cases_are_not_verified_when_target_results_are_invalid(self):
        variants = [
            BASE + f'➜ Test {MARKER}() skipped: synthetic reason.\n',
            BASE + f'✘ Test {MARKER}() failed after 0.01 seconds.\n',
            BASE + f'✔ Test {MARKER}() passed after 0.01 seconds.\n',
        ]
        for log in variants:
            with self.subTest(log=log):
                result = receipt.evaluate(log)
                self.assertTrue(result['falseCaseStarted'])
                self.assertTrue(result['trueCaseStarted'])
                self.assertTrue(result['twoCasePassedSummary'])
                self.assertEqual(result['status'], 'incomplete')
                self.assertFalse(result['bothCasesVerified'])

    def test_cases_without_complete_evidence_are_unverified(self):
        r = receipt.evaluate(BASE.replace('failLegacy → true', 'failLegacy → unknown'))
        self.assertEqual(r['status'], 'pass')
        self.assertFalse(r['bothCasesVerified'])

    def test_cli_output_does_not_include_private_log(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'log'
            p.write_text(BASE + '\nTOKEN=synthetic-private-value\n', encoding='utf-8')
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), str(p)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn('synthetic-private-value', result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)['status'], 'pass')


if __name__ == '__main__':
    unittest.main()
