import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chromium_154_reconstruction import ReconstructionError, sha256, verify_bound_transition
from chromium_154_source_transition import verify_transition
from test_chromium_154_source_transition import entry, snapshot


class BoundTransitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paths = {}
        self.binding = dict(baseline='baseline', inputs='inputs', report='report')
        self.steps = [dict(path='input.cc', beforeSHA256='a'*64,
                           afterSHA256='b'*64, patchSHA256='c'*64)]
        self.report = verify_transition(snapshot([entry()]),
                                        snapshot([entry(digest='b'*64)]), self.steps)
        self.put('replay', dict(self.steps[0], zeroFuzzZeroOffsetReplay=True))
        self.inputs = dict(overlaySteps=self.steps, verifiedCaches=[],
                           evidence=[dict(path='replay', sha256=sha256(self.paths['replay']))])
        self.put('inputs', self.inputs)
        self.report['privateExecution'] = {key: 'd'*64 for key in (
            'beforeFullSHA256', 'afterFullSHA256', 'driverSHA256', 'verifierSHA256')}
        self.report['privateExecution']['inputsSHA256'] = sha256(self.paths['inputs'])
        self.put('baseline', self.report['beforeSnapshot'])
        self.put('report', self.report)
        self.final = copy.deepcopy(self.report['afterSnapshot'])

    def put(self, name, value):
        self.paths[name] = self.root / name
        self.paths[name].write_text(json.dumps(value))

    def check(self):
        return verify_bound_transition(self.paths, self.binding, self.final)

    def test_valid_bound_delta(self):
        self.assertEqual(self.check()['boundTransitionChanges'], 1)

    def test_changed_snapshot_and_inputs_fail(self):
        self.final['entriesSHA256'] = 'e'*64
        with self.assertRaises(ReconstructionError): self.check()
        self.final = self.report['afterSnapshot']
        self.put('inputs', dict(self.inputs, overlaySteps=[]))
        with self.assertRaises(ReconstructionError): self.check()

    def test_omitted_duplicate_and_mode_changed_deltas_fail(self):
        mode_changed = copy.deepcopy(self.report['changes'])
        mode_changed[0]['after']['mode'] = 0o755
        for changes in ([], self.report['changes'] * 2, mode_changed):
            self.put('report', dict(self.report, changes=changes))
            with self.assertRaises(ReconstructionError): self.check()

    def test_forged_counts_and_missing_execution_digest_fail(self):
        report = copy.deepcopy(self.report)
        del report['privateExecution']['afterFullSHA256']
        self.put('report', report)
        with self.assertRaises(ReconstructionError): self.check()
        self.put('report', self.report)
        self.final['sourceFileCount'] += 1
        with self.assertRaises(ReconstructionError): self.check()

    def test_empty_evidence_and_rehashed_false_patch_fail(self):
        for inputs in (dict(self.inputs, evidence=[]), copy.deepcopy(self.inputs)):
            if inputs['evidence']:
                inputs['overlaySteps'][0]['patchSHA256'] = 'e'*64
            self.put('inputs', inputs)
            report = copy.deepcopy(self.report)
            report['overlaySteps'] = inputs['overlaySteps']
            report['privateExecution']['inputsSHA256'] = sha256(self.paths['inputs'])
            self.put('report', report)
            with self.assertRaises(ReconstructionError): self.check()

    def test_cache_source_must_match_independent_evidence(self):
        cache = dict(path='pkg/__pycache__/mod.cpython-311.pyc', sourcePath='mod.py',
                     sourceSHA256='a'*64, pycSHA256='b'*64, timestampAndCodeMatch=True)
        before = snapshot([entry('mod.py')])
        after = snapshot([entry('mod.py'), entry(cache['path'], 'b'*64)])
        report = verify_transition(before, after, [], [cache])
        self.put('cache', dict(passed=True, verifiedCacheCount=1, items=[cache]))
        inputs = dict(overlaySteps=[], verifiedCaches=[cache],
                      evidence=[dict(path='cache', sha256=sha256(self.paths['cache']))])
        self.put('inputs', inputs)
        report['privateExecution'] = dict(self.report['privateExecution'],
                                          inputsSHA256=sha256(self.paths['inputs']))
        self.put('baseline', report['beforeSnapshot'])
        self.put('report', report)
        self.final = report['afterSnapshot']
        self.assertEqual(self.check()['boundTransitionChanges'], 1)
        inputs['verifiedCaches'] = [dict(cache, sourceSHA256='e'*64)]
        self.put('inputs', inputs)
        report['verifiedCaches'] = inputs['verifiedCaches']
        report['privateExecution']['inputsSHA256'] = sha256(self.paths['inputs'])
        self.put('report', report)
        with self.assertRaises(ReconstructionError): self.check()


if __name__ == '__main__':
    unittest.main()
