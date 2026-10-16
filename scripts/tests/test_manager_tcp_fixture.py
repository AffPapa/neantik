"""Actual owned sockets test the fixture; these are not browser route tests."""
import base64
import errno
import importlib.util
from pathlib import Path
import socket
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('tcp_fixture_tests', Path(__file__).resolve().parents[1] / 'runtime-network/manager-tcp-fixture.py')
TCP = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(TCP)


class ManagerTCPFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-tcp-unit-')
        self.fixture = TCP.ManagerTCPFixture(Path(self.temp.name))

    def tearDown(self):
        self.assertTrue(self.fixture.close())
        self.temp.cleanup()

    def request(self, phase, protected=True, stream=False):
        f = self.fixture
        endpoint = f.proxy_address if protected else f.origin.server_address
        client = socket.create_connection(endpoint, timeout=2); client.settimeout(2)
        if protected:
            auth = base64.b64encode((TCP.BASE.QA_USER + ':' + TCP.BASE.QA_PASSWORD).encode())
            client.sendall(b'CONNECT 127.0.0.1:' + str(f.origin.server_address[1]).encode() + b' HTTP/1.1\r\nProxy-Authorization: Basic ' + auth + b'\r\n\r\n')
            self.assertTrue(TCP.BASE.header(client).startswith(b'HTTP/1.1 200 '))
        path = '/owned-stream' if stream else '/owned-route'
        client.sendall(('GET ' + path + '?phase=' + phase + '&nonce=' + f.nonces[phase] + ' HTTP/1.1\r\nHost: owned-fixture\r\n\r\n').encode())
        self.assertTrue(TCP.BASE.header(client).startswith(b'HTTP/1.1 200 '))
        return client

    def test_physical_refusal_direct_sensitivity_and_same_endpoint_recovery(self):
        f = self.fixture; endpoint = f.proxy_address
        self.request('proxy-success').close()
        self.assertEqual(f.apply_control('stop-listener'), {'faultEpoch':1, 'listenerActive':False})
        with socket.socket() as client:
            client.settimeout(1)
            self.assertEqual(client.connect_ex(endpoint), errno.ECONNREFUSED)
        self.request('direct-control', protected=False).close()
        self.assertEqual(f.apply_control('recover-listener'), {'faultEpoch':2, 'listenerActive':True})
        self.assertEqual(f.proxy.server_address, endpoint)
        self.request('proxy-recovered').close()
        controls = [e for e in f.ledger.events if e['kind']=='tcp-listener-control']
        self.assertEqual([c['listenerActive'] for c in controls], [True,False,True])
        self.assertTrue(controls[1]['socketProbeRefused']); self.assertTrue(controls[2]['sameEndpoint'])
        arrivals = [e for e in f.ledger.events if e['kind']=='tcp-origin-arrival']
        self.assertEqual([(e['phase'],e['throughOwnedUpstream']) for e in arrivals],
                         [('proxy-success',True),('direct-control',False),('proxy-recovered',True)])
        self.assertFalse(any(e['kind'] in ('upstream-refused','upstream-tcp-cut') for e in f.ledger.events))

    def test_live_stream_shutdown_precedes_recovery(self):
        client = self.request('proxy-success', stream=True)
        self.assertTrue(client.recv(64))
        self.fixture.apply_control('stop-listener')
        while client.recv(256): pass
        client.close()
        event = next(e for e in self.fixture.ledger.events if e['kind']=='tcp-listener-control' and not e['listenerActive'])
        self.assertGreaterEqual(event['acceptedChannelsShutdown'], 2)

    def test_invalid_or_duplicate_operator_controls_refused(self):
        for action in ['recover-listener','fail-dns','stop','unknown']:
            with self.assertRaises(ValueError): self.fixture.apply_control(action)
        self.fixture.apply_control('stop-listener')
        with self.assertRaises(ValueError): self.fixture.apply_control('stop-listener')

    def test_browser_urls_cannot_select_control_or_forge_nonce(self):
        f = self.fixture
        self.assertIsNone(f.phase('/stop-listener?phase=proxy-success&nonce='+f.nonces['proxy-success']))
        self.assertIsNone(f.phase('/owned-route?phase=listener-refused&nonce=wrong'))
        self.assertTrue(f.control_snapshot()['listenerActive'])
        self.assertEqual(set(f.description()['urls']), set(TCP.PHASES))


if __name__ == '__main__': unittest.main()
