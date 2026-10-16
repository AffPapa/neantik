#!/usr/bin/env python3
"""Deliberately broken observation controls; never launch a native component."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("assessor", Path(__file__).with_name("analyze-owned-filter.py"))
QA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QA)
RUN, ARCHIVE, PROVIDER = "owned-run", "archive-digest", "provider-digest"


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.report = {"schemaVersion": 1, "runID": RUN, "signedArchiveSHA256": ARCHIVE,
                       "providerPID": 41, "cases": [], "providerEvents": []}
        self.event("applied", 10)
        self.event("unavailable", 30)
        for phase, base in (("baseline", 1), ("active", 11), ("unavailable", 31)):
            for index, (family, role) in enumerate((('v4','B'), ('v4','A'), ('v6','B'), ('v6','A'))):
                start = base + 2 * index
                load = phase == "baseline" or role == "B"
                observation = {"runID": RUN, "role": role, "outcome": "loaded" if load else "failure", "uptime": start + 0.9}
                observation.update({"httpStatus": 200} if load else {"errorDomain": "NSURLErrorDomain", "errorCode": -1004})
                self.report['cases'].append({"phase": phase, "family": family, "role": role,
                    "startUptime": start, "endUptime": start + 1, "observation": observation,
                    "exitCode": 0, "outerTimeout": False, "forcedKill": False,
                    "originEvents": [{"uptime": start + 0.5}] if load else []})
                if phase == "active":
                    self.event("A-drop" if role == "A" else "B-allow", start + 0.5)

    def event(self, kind, uptime):
        self.report['providerEvents'].append({"kind": kind, "uptime": uptime, "runID": RUN,
            "providerPID": 41, "providerExecutableSHA256": PROVIDER})

    def result(self):
        return QA.assess(self.report, run_id=RUN, archive_sha256=ARCHIVE, provider_sha256=PROVIDER)

    def test_complete_control_still_does_not_qualify_product(self):
        result = self.result()
        self.assertEqual(result['problems'], [])
        self.assertFalse(result['productionQualified'])
        self.assertFalse(result['workingProxyProved'])

    def test_current_baseline_alone_is_incomplete(self):
        self.report['cases'] = self.report['cases'][:4]
        self.assertIn('incomplete_case_matrix', self.result()['problems'])

    def test_direct_after_provider_loss_is_caught(self):
        case = self.report['cases'][-1]
        case['originEvents'] = [{}]
        case['observation'].update(outcome='loaded', httpStatus=200)
        self.assertTrue(any('direct_or_unproved_block' in x for x in self.result()['problems']))

    def test_failing_b_cannot_prove_selective_a_block(self):
        case = self.report['cases'][4]
        case['originEvents'] = []
        case['observation'].update(outcome='failure', errorDomain='NSURLErrorDomain', errorCode=-1009)
        self.assertTrue(any('positive_control_failed' in x for x in self.result()['problems']))

    def test_unknown_callback_or_wrong_code_never_disappears(self):
        clean = copy.deepcopy(self.report)
        for field, value in [('kind','unknown-owner'), ('providerPID',42), ('providerExecutableSHA256','other'), ('runID','other')]:
            self.report = copy.deepcopy(clean)
            self.report['providerEvents'][0][field] = value
            self.assertTrue(self.result()['problems'])

    def test_missing_timing_or_unmatched_event_is_caught(self):
        clean = copy.deepcopy(self.report)
        for field in ['startUptime', 'endUptime']:
            self.report = copy.deepcopy(clean)
            self.report['cases'][5].pop(field)
            self.assertTrue(any('missing_exact_interval' in x for x in self.result()['problems']))
        self.report = clean
        self.report['providerEvents'] = [e for e in clean['providerEvents'] if e['kind'] != 'A-drop']
        self.assertTrue(any('no_matching_original_owner_event' in x for x in self.result()['problems']))

    def test_failure_barrier_must_precede_probe(self):
        next(e for e in self.report['providerEvents'] if e['kind']=='unavailable')['uptime'] = 100
        self.assertTrue(any('provider_failure_not_observed_before_request' in x for x in self.result()['problems']))

    def test_duplicate_case_and_timeout_refuse(self):
        self.report['cases'].append(copy.deepcopy(self.report['cases'][0]))
        self.report['cases'][5]['outerTimeout'] = True
        result = self.result()
        self.assertIn('duplicate_or_unexpected_case', result['problems'])
        self.assertTrue(any('host_not_completed' in x for x in result['problems']))

    def test_stale_or_malformed_origin_evidence_refuses(self):
        case = self.report['cases'][4]
        case['originEvents'] = [{'uptime': 2}]
        self.assertTrue(any('stale_origin_event' in x for x in self.result()['problems']))
        case['originEvents'] = [{}]
        self.assertTrue(any('invalid_origin_event' in x for x in self.result()['problems']))

    def test_malformed_matrix_key_is_reported_without_crashing(self):
        self.report['cases'][4]['phase'] = []
        self.assertIn('duplicate_or_unexpected_case', self.result()['problems'])

    def test_retained_baseline_uses_actual_origin_and_host_completion(self):
        for case in self.report['cases'][:4]:
            case.pop('startUptime')
            case.pop('endUptime')
        self.assertEqual(self.result()['problems'], [])
        self.report['cases'][0]['observation'].pop('uptime')
        self.assertTrue(any('stale_or_unordered_baseline' in x for x in self.result()['problems']))

    def test_stale_and_after_apply_baseline_refuse(self):
        case = self.report['cases'][0]
        case['originEvents'][0]['uptime'] = 40
        case['observation']['uptime'] = 40.1
        self.assertTrue(any('baseline' in x for x in self.result()['problems']))
        case['originEvents'][0]['uptime'] = -100
        self.assertTrue(any('invalid_origin_event' in x for x in self.result()['problems']))

    def test_huge_integer_is_invalid_evidence_not_an_exception(self):
        self.report['cases'][0]['originEvents'][0]['uptime'] = 10**400
        self.assertTrue(any('invalid_origin_event' in x for x in self.result()['problems']))


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.run = 'a0000000-0000-4000-8000-000000000001'
        self.image = 'b0000000-0000-4000-8000-000000000002'
        self.record = {'processID': 41, 'processImagePath': '/owned/Provider', 'processImageUUID': self.image.upper(),
                       'subsystem': 'app.neantik.desktop.network-qa.proxy', 'category': 'owned-loopback',
                       'timestamp': '2026-10-16 00:00:00.500000+0000',
                       'eventMessage': 'owned-filter-start success=true run=' + self.run.upper()}
        self.anchor = {'timestamp': '2026-10-16T00:00:00+00:00', 'uptime': 100}
        self.checks = [{'timestamp': '2026-10-16T00:00:01+00:00', 'uptime': 101}]

    def result(self):
        return QA.normalize_journal([self.record], run_id=self.run, provider_pid=41, provider_sha256=PROVIDER,
            process_image_path='/owned/Provider', process_image_uuid=self.image,
            clock_anchor=self.anchor, clock_checks=self.checks)

    def test_real_os_schema_and_uuid_case_normalization(self):
        result = self.result()
        self.assertEqual(result['problems'], [])
        self.assertEqual(result['events'][0]['kind'], 'applied')
        self.assertEqual(result['events'][0]['uptime'], 100.5)
        self.assertFalse(result['collectionAuthenticated'])

    def test_wrong_image_or_malformed_timestamp_refuse(self):
        for key, value in [('processImagePath','/unrelated/Other'), ('timestamp',42), ('processImageUUID','invalid')]:
            clean = copy.deepcopy(self.record)
            self.record[key] = value
            self.assertEqual(self.result()['events'], [])
            self.assertTrue(self.result()['problems'])
            self.record = clean

    def test_unknown_owner_and_unexpected_messages_remain_disqualifying(self):
        for message, kind in [('owned-filter-flow role=unknown verdict=allow UNQUALIFIED run=' + self.run, 'unknown-owner'),
                              ('owned-filter-unexpected UNQUALIFIED reason=endpoint-unavailable', 'unexpected-callback'),
                              ('new-unrecognized-message', 'unexpected-message')]:
            self.record['eventMessage'] = message
            self.assertEqual(self.result()['events'][0]['kind'], kind)

    def test_stop_callback_never_becomes_provider_unavailable(self):
        self.record['eventMessage'] = 'owned-filter-stop;OS failure behavior remains separately measured'
        self.assertEqual(self.result()['events'][0]['kind'], 'stop-request')

    def test_wall_clock_drift_is_a_setup_refusal(self):
        self.checks[0]['uptime'] = 102
        self.assertEqual(self.result()['events'], [])
        self.assertTrue(self.result()['problems'])

    def test_foreign_run_does_not_silently_disappear(self):
        self.record['eventMessage'] = 'owned-filter-start success=true run=b0000000-0000-4000-8000-000000000001'
        self.assertEqual(self.result()['events'], [])
        self.assertTrue(self.result()['problems'])


if __name__ == '__main__':
    unittest.main()
