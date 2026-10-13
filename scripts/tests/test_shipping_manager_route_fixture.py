"""Real owned localhost sensitivity controls; no browser qualification by mocks."""
import base64
import importlib.util
from pathlib import Path
import socket
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'runtime-network/manager-route-fixture.py'
SPEC = importlib.util.spec_from_file_location('manager_route_fixture', SOURCE)
MODULE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MODULE)


class ShippingRouteFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-route-unit-')
        self.fixture = MODULE.Fixture(Path(self.temp.name))
    def tearDown(self):
        self.assertTrue(self.fixture.close())
        self.temp.cleanup()
    def connection(self, phase, proxy=False, path='/owned-route'):
        f = self.fixture
        channel = socket.create_connection(('127.0.0.1', f.proxy.server_address[1] if proxy else f.origin.server_address[1]), timeout=3)
        channel.settimeout(3)
        if proxy:
            auth = base64.b64encode((MODULE.QA_USER + ':' + MODULE.QA_PASSWORD).encode())
            channel.sendall(b'CONNECT 127.0.0.1:' + str(f.origin.server_address[1]).encode() + b' HTTP/1.1\r\nProxy-Authorization: Basic ' + auth + b'\r\n\r\n')
            response = MODULE.header(channel)
            if not response.startswith(b'HTTP/1.1 200 '): return channel, response
        target = path + '?phase=' + phase + '&nonce=' + f.nonces[phase]
        channel.sendall(b'GET ' + target.encode() + b' HTTP/1.1\r\nHost: owned-fixture\r\n\r\n')
        return channel, MODULE.header(channel)
    def test_proxy_and_direct_have_independent_nonce_bound_origin_receipts(self):
        for proxy in (True, False):
            channel, response = self.connection('proxy-success', proxy)
            self.assertTrue(response.startswith(b'HTTP/1.1 200 ')); channel.close()
        hits = [e for e in self.fixture.ledger.events if e['kind']=='origin']
        self.assertEqual([e['throughOwnedUpstream'] for e in hits], [True, False])
        self.assertIsNone(self.fixture.phase('/owned-route?phase=proxy-success&nonce=wrong'))
        self.assertIsNone(self.fixture.phase('/foreign?phase=proxy-success&nonce='+self.fixture.nonces['proxy-success']))
    def test_refused_proxy_does_not_hit_origin_while_direct_control_still_can(self):
        (self.fixture.root/'drop-upstream').touch()
        channel, response = self.connection('upstream-refused', True)
        self.assertTrue(response.startswith(b'HTTP/1.1 502 ')); channel.close()
        self.assertFalse(any(e['kind']=='origin' for e in self.fixture.ledger.events))
        channel, response = self.connection('upstream-refused', False)
        self.assertTrue(response.startswith(b'HTTP/1.1 200 ')); channel.close()
        self.assertEqual(sum(e['kind']=='origin' and not e['throughOwnedUpstream'] for e in self.fixture.ledger.events), 1)
    def test_actual_established_stream_is_cut_and_new_connection_refused(self):
        channel, response = self.connection('proxy-success', True, '/owned-stream')
        self.assertTrue(response.startswith(b'HTTP/1.1 200 '))
        self.assertTrue(channel.recv(64))
        (self.fixture.root/'cut-upstream').touch()
        deadline = time.monotonic()+3
        while time.monotonic()<deadline and not any(e['kind']=='cut-active-local-channels' for e in self.fixture.ledger.events): time.sleep(.02)
        cut = next(e for e in self.fixture.ledger.events if e['kind']=='cut-active-local-channels')
        self.assertGreaterEqual(cut['channels'], 2)
        # Drain buffered heartbeat bytes until EOF, rather than mistaking one buffered read for survival.
        while channel.recv(256): pass
        channel.close()
        with socket.create_connection(('127.0.0.1', self.fixture.proxy.server_address[1]), timeout=3) as client:
            auth=base64.b64encode((MODULE.QA_USER+':'+MODULE.QA_PASSWORD).encode())
            client.sendall(b'CONNECT 127.0.0.1:'+str(self.fixture.origin.server_address[1]).encode()+b' HTTP/1.1\r\nProxy-Authorization: Basic '+auth+b'\r\n\r\n')
            self.assertEqual(client.recv(64), b'')
        (self.fixture.root/'cut-upstream').unlink()
        channel, response = self.connection('proxy-recovered', True)
        self.assertTrue(response.startswith(b'HTTP/1.1 200 ')); channel.close()

    def test_automatic_cut_waits_for_real_protected_stream_data(self):
        arm = self.fixture.root / 'arm-cut-on-stream'
        arm.touch()
        # A Direct stream must not activate the proxy fault.
        direct, _ = self.connection('proxy-success', False, '/owned-stream')
        self.assertTrue(direct.recv(64)); direct.close()
        self.assertTrue(arm.exists())
        self.assertFalse((self.fixture.root / 'cut-upstream').exists())
        protected, _ = self.connection('proxy-success', True, '/owned-stream')
        self.assertTrue(protected.recv(64))
        while protected.recv(256): pass
        protected.close()
        self.assertFalse(arm.exists())
        events = self.fixture.ledger.events
        heartbeat = next(e for e in events if e['kind']=='stream-first-heartbeat' and e['throughOwnedUpstream'])
        cut = next(e for e in events if e['kind']=='cut-active-local-channels')
        self.assertGreaterEqual(cut['channels'], 2)
        self.assertLessEqual(heartbeat['at'], cut['at'])

    def test_process_custody_rejects_ordinary_or_wrong_runtime(self):
        browser = Path('/owned/NeAntik Browser')
        data = Path('/private/tmp/owned-audit/manager-data')
        flags = '--user-data-dir=' + str(data) + '/Profiles/id/BrowserData --use-mock-keychain'
        row = '123 501 ' + str(browser) + ' ' + flags
        self.assertEqual(MODULE.owned_browser_pids([row], browser, data, 501), [123])
        for wrong in [row.replace('501', '502'), row.replace(str(browser), '/other/NeAntik Browser'),
                      row.replace(str(data), str(data)+'-ordinary'), row.replace('--use-mock-keychain', ''),
                      row.replace('--user-data-dir=', '--untrusted-root=')]:
            self.assertEqual(MODULE.owned_browser_pids([wrong], browser, data, 501), [])


if __name__=='__main__': unittest.main()
