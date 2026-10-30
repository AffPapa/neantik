"""Analyzer sensitivity controls; synthetic receipts never qualify a browser."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('route_analysis', Path(__file__).resolve().parents[1] / 'runtime-network/analyze-manager-route.py')
MODULE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MODULE)


def receipts():
    def event(kind, at, **fields): return dict(kind=kind, at=at, **fields)
    return {
        'fixture-ledger.json': dict(serverThreadsDrained=True, events=[
            event('origin', 1, phase='proxy-success', throughOwnedUpstream=True),
            event('origin-stream', 2, phase='proxy-success', throughOwnedUpstream=True),
            event('cut-active-local-channels', 3, channels=2),
            event('upstream-tcp-cut', 4),
            event('origin', 10, phase='proxy-recovered', throughOwnedUpstream=True),
            event('cut-active-local-channels', 11, channels=0),
            event('origin', 12, phase='upstream-cut', throughOwnedUpstream=False)]),
        'owned-browser-launch.json': dict(headedShippingManager=True, runtimeProcesses=[dict(
            pid=123, mockKeychain=True, ownedData=True, proxyConfigured=True,
            loopbackBypassDisabled=True, credentialsInArgv=False)]),
        'active-cut-receipt.json': dict(runtimePID=123, protectedFreshStreamBeforeCut=True, channelsCut=2, streamAgeAtCutSeconds=1),
        'after-cut-counts.json': dict(activeChannelsCut=2, upstreamTCPCutAttempts=1, cutPhaseOriginHits=0, directOriginHits=0, afterCutSeconds=6),
        'recovery-counts.json': dict(runtimePID=123, recoveredProxyHits=1, directRecoveryHits=0),
        'direct-negative-control.json': dict(sameCanaryReachableDirect=True, upstreamStillCut=True,
                                             originHitsDuringProtectedFailure=0, originHitsWithIntentionalDirectControl=1),
        'cleanup.json': dict(ownedProcessesRemaining=0, ordinaryInstanceTouched=False),
    }


class RouteAnalysisTests(unittest.TestCase):
    def test_complete_scoped_receipt_never_claims_full_gate_or_graceful_close(self):
        result = MODULE.qualify(receipts())
        self.assertEqual(result['result'], 'scoped-observations-pass')
        self.assertFalse(result['majorReleaseGate'])
        self.assertFalse(result['gracefulCloseQualified'])
        self.assertIn('DNS', result['open'])

    def test_every_missing_input_and_empty_ledger_fail(self):
        for name in MODULE.INPUTS:
            value = receipts(); del value[name]
            with self.assertRaises(ValueError): MODULE.qualify(value)
        value = receipts(); value['fixture-ledger.json']['events'] = []
        with self.assertRaises(ValueError): MODULE.qualify(value)

    def test_deliberate_bypass_is_caught_even_when_summary_claims_zero(self):
        value = receipts()
        value['fixture-ledger.json']['events'].insert(4, dict(kind='origin', at=5, phase='upstream-cut', throughOwnedUpstream=False))
        with self.assertRaisesRegex(ValueError, 'origin-hit-during-outage'): MODULE.qualify(value)

    def test_broken_controls_and_stale_session_fail(self):
        cases = [('active-cut-receipt.json', 'channelsCut', 0),
                 ('active-cut-receipt.json', 'streamAgeAtCutSeconds', 180),
                 ('direct-negative-control.json', 'originHitsWithIntentionalDirectControl', 0),
                 ('recovery-counts.json', 'runtimePID', 456),
                 ('cleanup.json', 'ownedProcessesRemaining', 1),
                 ('after-cut-counts.json', 'afterCutSeconds', 0)]
        for name, field, bad in cases:
            value = receipts(); value[name][field] = bad
            with self.assertRaises(ValueError, msg=field): MODULE.qualify(value)

    def test_ambiguous_or_unordered_observations_fail(self):
        for bad in (None, 'true', 1):
            value = receipts(); value['fixture-ledger.json']['events'][0]['throughOwnedUpstream'] = bad
            with self.assertRaises(ValueError): MODULE.qualify(value)

    def test_bool_counter_and_nonfinite_duration_are_not_measurements(self):
        for name, field, bad in [('after-cut-counts.json', 'cutPhaseOriginHits', False),
                                 ('active-cut-receipt.json', 'streamAgeAtCutSeconds', True),
                                 ('after-cut-counts.json', 'afterCutSeconds', float('inf'))]:
            value = receipts(); value[name][field] = bad
            with self.assertRaises(ValueError): MODULE.qualify(value)
        for bad in (float('nan'), -1):
            value = receipts(); value['fixture-ledger.json']['events'][-1]['at'] = bad
            with self.assertRaises(ValueError): MODULE.qualify(value)


if __name__ == '__main__': unittest.main()
