"""Broken retained fixtures must fail; no mock report is a browser PASS."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import unittest

SOURCE = Path(__file__).resolve().parents[1]/'runtime-network/analyze-controlled-dns.py'
SPEC = importlib.util.spec_from_file_location('controlled_dns_analysis', SOURCE)
MOD = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)


def fixture():
    release = dict(version='own-test', build=1, managerSHA256='a'*64,
                   runtime=dict(executableSHA256='b'*64, frameworkSHA256='c'*64, chromiumVersion='156'))
    report = dict(schemaVersion=1, status='observed', headed=True,
        environment=dict(platform='darwin', architecture='arm64'),
        runtimeSHA256='b'*64, frameworkSHA256='c'*64, runtimeVersion='156',
        managerSHA256='a'*64, releaseVersion='own-test', releaseBuild=1,
        fixtureConfigurationSHA256='d'*64, releaseReportSHA256='e'*64,
        sourceFiles={str(n):'f'*64 for n in range(4)}, sessions=[])
    for mode, names in [('proxy', ['proxy-success', 'upstream-cut', 'dns-refused', 'upstream-refused', 'proxy-recovered']),
                        ('direct', ['doh-refused', 'direct-control']), ('bypass', ['bypass-control'])]:
        session = dict(mode=mode, sessionID=mode, configurationSHA256='e'*64,
            profileRootSHA256={'proxy':'a','direct':'b','bypass':'c'}[mode]*64,
            status='observed', cleanup=dict(browserExited=True, ownedProcessesRemaining=0),
            readiness=dict(eligibleForAttempt=True), observations=[], establishedStreamCut=True)
        report['sessions'].append(session)
        for phase in names:
            row = dict(phase=phase, udpAnswers=0, udpFailures=0, dohAnswers=0, dohFailures=0,
                       protectedOrigins=0, directOrigins=0, committed=False, navigationError='net::ERR_FAILED')
            if phase in ('proxy-success', 'proxy-recovered', 'direct-control', 'bypass-control'):
                row.update(committed=True, navigationError=None)
                row['protectedOrigins' if mode=='proxy' else 'directOrigins'] = 1
                row['udpAnswers' if mode=='proxy' else 'dohAnswers'] = 1
            if phase == 'dns-refused': row['udpFailures'] = 1
            if phase == 'doh-refused': row['dohFailures'] = 1
            session['observations'].append(row)
    return report, release


class ControlledDNSAnalysisTests(unittest.TestCase):
    def test_consistent_fixture_keeps_manager_global_dns_and_tls_limits_explicit(self):
        report, release = fixture(); result = MOD.analyze(report, release)
        self.assertEqual(result['observations'], 8)
        self.assertFalse(result['allNetworkGatesComplete'])
        self.assertFalse(result['actualManagerRelay'])

    def test_missing_duplicate_failed_or_headless_context_cannot_be_pass(self):
        report, release = fixture()
        changes = [lambda r:r.update(status='failed'), lambda r:r.update(headed=False),
                   lambda r:r['sessions'].pop(), lambda r:r['sessions'][0]['observations'].pop(),
                   lambda r:r['sessions'][0].update(status='incomplete'),
                   lambda r:r['sessions'][0]['cleanup'].update(ownedProcessesRemaining=1),
                   lambda r:r['sessions'][0]['readiness'].update(eligibleForAttempt=False),
                   lambda r:r['sessions'][0].update(establishedStreamCut=False),
                   lambda r:r.update(runtimeSHA256='f'*64),
                   lambda r:r['sessions'][1].update(sessionID='proxy'),
                   lambda r:r['sessions'][1].update(profileRootSHA256='a'*64)]
        for change in changes:
            wrong = copy.deepcopy(report); change(wrong)
            with self.assertRaises(ValueError): MOD.analyze(wrong, release)

    def test_each_observation_requires_real_count_route_and_navigation_evidence(self):
        report, release = fixture()
        for session in report['sessions']:
            for row in session['observations']:
                for field in ('udpAnswers', 'udpFailures', 'dohAnswers', 'dohFailures', 'protectedOrigins', 'directOrigins', 'committed'):
                    wrong = copy.deepcopy(report)
                    counterpart = next(r for s in wrong['sessions'] for r in s['observations'] if r['phase']==row['phase'])
                    del counterpart[field]
                    with self.subTest(phase=row['phase'], field=field):
                        with self.assertRaises(ValueError): MOD.analyze(wrong, release)
        for phase, update in [('dns-refused', {'udpFailures':0}), ('doh-refused', {'dohFailures':0}),
                              ('upstream-cut', {'directOrigins':1}), ('proxy-recovered', {'dohAnswers':1}),
                              ('direct-control', {'dohAnswers':0}), ('bypass-control', {'directOrigins':0}),
                              ('proxy-success', {'udpAnswers':True}), ('dns-refused', {'navigationError':None})]:
            wrong = copy.deepcopy(report)
            next(r for s in wrong['sessions'] for r in s['observations'] if r['phase']==phase).update(update)
            with self.subTest(phase=phase, update=update):
                with self.assertRaises(ValueError): MOD.analyze(wrong, release)

    def test_pipe_protocol_real_stream_positive_bounds_refusal_and_timeout_controls(self):
        node = shutil.which('node')
        if node is None: self.skipTest('Node required for pipe transport controls')
        result = subprocess.run([node, str(SOURCE.with_name('run-controlled-dns.mjs')), '--protocol-controls'],
                                capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual(json.loads(result.stdout), {'protocolControls':6, 'actualBrowser':False})


if __name__ == '__main__': unittest.main()
