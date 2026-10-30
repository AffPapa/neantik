import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'runtime-network' / 'prepare-webkit-ab-isolation-qa.py'
SPEC = importlib.util.spec_from_file_location('webkit_ab_qa', SCRIPT)
QA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QA)


def blank_profile():
    return {
        'id': '00000000-0000-4000-8000-000000000001',
        'name': QA.BLANK_PROFILE_NAME,
        'engine': 'webkit',
        'webKitRuntimeGeneration': 'system',
        'startURL': 'about:blank',
        'proxy': None,
        'identity': {
            'seed': 2, 'deviceTupleID': 'macbook-air-m2',
            'catalogVersion': 1, 'issuanceVersion': 2,
        },
        'note': '', 'tags': [],
    }


def counters(*, pages=0, initial=0, restored=0, proxy_a=0, proxy_b=0):
    return {
        'origin': {
            'pageResponses': pages,
            'stateInitial': initial,
            'stateRestored': restored,
            'requestTrace': [],
        },
        'proxyAAuthorizedOrigins': proxy_a,
        'proxyBAuthorizedOrigins': proxy_b,
    }


class WebKitABIsolationFixtureTests(unittest.TestCase):
    def test_seed_uses_same_origin_separate_proxies_and_identity_seeds(self):
        data = json.loads(QA.profile_bytes(blank_profile(), origin_url='https://a.neantik-dns.invalid:443/',
                                           proxy_ports=(51001, 51002)))
        a, b = data['profiles']
        self.assertEqual(data['schemaVersion'], 5)
        self.assertEqual(a['startURL'], b['startURL'])
        self.assertEqual(a['proxy']['port'], 51001)
        self.assertEqual(b['proxy']['port'], 51002)
        self.assertEqual(a['webKitRuntimeGeneration'], 'isolatedV1')
        self.assertEqual(b['webKitRuntimeGeneration'], 'isolatedV1')
        self.assertNotEqual(a['id'], b['id'])
        self.assertNotEqual(a['identity']['seed'], b['identity']['seed'])
        self.assertEqual(a['identity']['deviceTupleID'], 'macbook-air-m2')
        self.assertEqual(b['identity']['deviceTupleID'], 'macbook-air-m2')
        for profile in (a, b):
            self.assertEqual(profile['identity']['seed'] % QA.TUPLE_COUNT, QA.M2_RESIDUE)
            self.assertEqual(profile['identity']['issuanceVersion'], 2)

    def test_peer_control_seed_has_explicit_opposite_policies(self):
        data = json.loads(QA.profile_bytes(blank_profile(), origin_url='https://a.neantik-dns.invalid:443/',
                                           proxy_ports=(51001, 51002), peer_control=True))
        self.assertEqual(data['schemaVersion'], 6)
        self.assertEqual([p['webKitBlockPeerConnections'] for p in data['profiles']], [True, False])

    def test_duplicate_proxy_port_is_refused(self):
        with self.assertRaises(QA.FixtureError):
            QA.profile_bytes(blank_profile(), origin_url='https://a.neantik-dns.invalid:443/',
                             proxy_ports=(51001, 51001))

    def test_prepare_binds_two_loopback_tunnels_and_stops_cleanly(self):
        with tempfile.TemporaryDirectory(prefix='neantik-webkit-ab-template-') as directory:
            path = Path(directory) / 'profiles.json'
            path.write_text(json.dumps({'schemaVersion': 2, 'profiles': [blank_profile()]}))
            plan, dns, origin, tunnels, validator = QA.prepare(path)
            try:
                self.assertEqual(plan['status'], 'offline-fixture-ready; browser-not-started')
                self.assertRegex(plan['root'], r'^/private/tmp/neantik-production-diagnostic-[A-Za-z0-9_]+$')
                self.assertEqual(plan['profileCount'], 2)
                self.assertNotEqual(plan['proxyA'], plan['proxyB'])
                self.assertTrue(plan['sameOrigin'].startswith('https://'))
                self.assertEqual(origin.snapshot()['pageResponses'], 0)
                self.assertEqual(validator.snapshot(), {'accepted': 0, 'refused': 0})
                for tunnel in tunnels:
                    with socket.create_connection(('127.0.0.1', tunnel.port), timeout=1):
                        pass
            finally:
                closed = [tunnel.stop() for tunnel in reversed(tunnels)]
                origin_closed = origin.stop()
                dns_closed = dns.close()
                self.assertTrue(all(closed) and origin_closed and dns_closed)
                root = Path(plan['root'])
                stage = Path(plan['stage'])
                import shutil
                shutil.rmtree(root)
                shutil.rmtree(stage)

    def test_peer_control_fixture_uses_loopback_probe_and_explicit_policies(self):
        with tempfile.TemporaryDirectory(prefix='neantik-webkit-peer-template-') as directory:
            path = Path(directory) / 'profiles.json'
            path.write_text(json.dumps({'schemaVersion': 2, 'profiles': [blank_profile()]}))
            with self.assertRaises(QA.FixtureError): QA.prepare(path, peer_control=True)
            plan, dns, origin, tunnels, validator = QA.prepare(path, peer_control=True, peer_stun_port=34567, gpu_probe=True)
            try:
                document = json.loads((Path(plan['root']) / 'profiles.json').read_text())
                self.assertEqual(document['schemaVersion'], 6)
                self.assertEqual([p['webKitBlockPeerConnections'] for p in document['profiles']], [True, False])
                self.assertEqual(plan['peerProbeLoopbackPort'], 34567)
                self.assertIn('stun:127.0.0.1:34567', origin.marker)
                self.assertIn('peer-probe', origin.marker)
                self.assertTrue(plan['gpuProbe'])
                self.assertIn('navigator.gpu.requestAdapter()', origin.marker)
                self.assertIn('/qa-peer/', origin.marker)
                self.assertIn("r.timeout ? 'timeout'", origin.marker)
                self.assertIn('Promise.race', origin.marker)
            finally:
                for tunnel in reversed(tunnels): tunnel.stop()
                origin.stop(); dns.close()
                import shutil
                shutil.rmtree(plan['root']); shutil.rmtree(plan['stage'])

    def test_peer_probe_rejects_invalid_nonce(self):
        with self.assertRaises(QA.FixtureError):
            QA.peer_probe_fragment(34567, 'not-a-nonce')

    def test_gpu_probe_is_opt_in_and_bounded(self):
        with self.assertRaises(QA.FixtureError): QA.gpu_probe_fragment('invalid')
        fragment = QA.gpu_probe_fragment('a' * 32)
        self.assertIn('navigator.gpu.requestAdapter()', fragment)
        self.assertIn("resolve('timeout')", fragment)
        self.assertIn('/qa-gpu/' + 'a' * 32, fragment)

    def test_public_site_redirect_is_closed_list_and_requires_valid_nonce(self):
        for name, url in [('google', 'https://www.google.com/'), ('booking', 'https://www.booking.com/')]:
            page = QA.public_site_page('a' * 32, name)
            self.assertIn(url, page)
            self.assertIn('location.replace', page)
        with self.assertRaises(QA.FixtureError): QA.public_site_page('a' * 32, 'https://untrusted.invalid/')
        with self.assertRaises(ValueError): QA.public_site_page('invalid', 'google')

    def test_phase_capture_waits_until_expected_proxy_and_state_arrive(self):
        prior = counters(pages=1, initial=1, proxy_a=2)
        observations = iter((
            counters(pages=1, initial=1, proxy_a=2),
            counters(pages=2, initial=1, restored=1, proxy_a=4),
        ))
        result, observed = QA._wait_for_phase(
            'A2', prior, lambda: next(observations), timeout_seconds=0.5,
            poll_interval=0.001)
        self.assertEqual(result['classification'], 'pass')
        self.assertEqual(result['proxyAAuthorizedOriginDelta'], 2)
        self.assertEqual(result['stateDelta'], {
            'pageResponses': 1, 'stateInitial': 0, 'stateRestored': 1,
        })
        self.assertEqual(observed['proxyAAuthorizedOrigins'], 4)

    def test_phase_capture_rejects_late_mixed_snapshot_without_consuming_it(self):
        prior = counters(pages=1, initial=1, proxy_a=2)
        # This is the observed V280 shape: B1 and A2 were both inside the
        # interval, so neither phase may consume this combined delta.
        mixed = counters(pages=3, initial=2, restored=1, proxy_a=4, proxy_b=2)
        result = QA._phase_observation('B1', prior, mixed)
        self.assertEqual(result['classification'], 'contaminated')

    def test_phase_capture_rejects_wrong_proxy_even_when_page_loaded(self):
        prior = counters()
        result = QA._phase_observation(
            'B1', prior, counters(pages=1, initial=1, proxy_a=2))
        self.assertEqual(result['classification'], 'fail')
        self.assertEqual(result['routeBoundary'], 'FAIL')
        self.assertEqual(result['storageBoundary'], 'PASS')

    def test_phase_a2_requires_proxy_a_and_restored_state(self):
        prior = counters(pages=1, initial=1, proxy_a=2, proxy_b=2)
        result = QA._phase_observation(
            'A2', prior, counters(pages=2, initial=1, restored=1, proxy_a=2, proxy_b=2))
        self.assertEqual(result['classification'], 'fail')
        self.assertEqual(result['routeBoundary'], 'FAIL')
        self.assertEqual(result['storageBoundary'], 'PASS')


if __name__ == '__main__':
    unittest.main()
