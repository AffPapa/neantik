import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('font_skia', ROOT / 'scripts/runtime-platform/analyze-font-skia.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def sample(policy):
    return dict(cases=[dict(case=name, **{key: True for key in fields})
                       for name, fields in module.CASES.items()], complete=True,
                schemaVersion=1, policy=policy, registrationScope='process',
                ownCanaryAbsentBefore=True, ownRegistrationRemoved=True,
                actualSkia=True, browserQualified=False)


class FontSkiaTests(unittest.TestCase):
    def test_native_policy_observer_are_distinct_and_all_cases_required(self):
        self.assertEqual(module.check_observation(sample(False), 'native')['cases'], 6)
        self.assertEqual(module.check_observation(sample(True), 'policy')['cases'], 6)
        self.assertTrue(module.check_observation(dict(schemaVersion=1, observer=True, ownCanaryAbsent=True), 'observe')['observer'])
        with self.assertRaises(ValueError):
            module.check_observation(sample(False), 'policy')

    def test_any_failed_case_missing_operation_extra_metadata_or_cleanup_refuses(self):
        for i, row in enumerate(sample(True)['cases']):
            for key in set(row) - {'case'}:
                for wrong in (False, None, 1):
                    value = sample(True)
                    value['cases'][i][key] = wrong
                    with self.assertRaises(ValueError):
                        module.check_observation(value, 'policy')
        for mutate in (lambda v: v['cases'].pop(), lambda v: v['cases'].append(v['cases'][0]),
                       lambda v: v.update(ownRegistrationRemoved=False),
                       lambda v: v.update(complete=False), lambda v: v.update(browserQualified=True),
                       lambda v: v['cases'][0].update(rawFontMetadata='forbidden')):
            value = sample(True)
            mutate(value)
            with self.assertRaises(ValueError):
                module.check_observation(value, 'policy')

    def test_native_exit_admission_and_full_cleanup_are_required(self):
        rows = [dict(mode=mode, exitCode=0, timedOut=False, signal=None,
                     admission=dict(exitCode=0, readiness=dict(eligibleForAttempt=True)),
                     observation=sample(mode == 'policy') if mode != 'observe' else
                     dict(schemaVersion=1, observer=True, ownCanaryAbsent=True))
                for mode in ('native', 'policy', 'observe')]
        report = dict(status='observed', inputsRechecked=True, sessions=rows,
                      cleanup=dict(ownedProcessesRemaining=0, ownedRootsRemaining=0))
        self.assertEqual(module.check_report(report)['status'], 'passed')
        for mutate in (lambda v: v['sessions'].pop(), lambda v: v['sessions'][0].update(exitCode=1),
                       lambda v: v['sessions'][0].update(timedOut=True),
                       lambda v: v['sessions'][1]['admission'].update(exitCode=75),
                       lambda v: v.update(inputsRechecked=False),
                       lambda v: v['cleanup'].update(ownedProcessesRemaining=1)):
            value = copy.deepcopy(report)
            mutate(value)
            with self.assertRaises(ValueError):
                module.check_report(value)


if __name__ == '__main__':
    unittest.main()
