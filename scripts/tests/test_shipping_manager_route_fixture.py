"""Real owned localhost sensitivity controls; no browser qualification by mocks."""
import base64
import importlib.util
from pathlib import Path
import socket
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'runtime-network/manager-route-fixture.py'
SPEC = importlib.util.spec_from_file_location('manager_route_fixture', SOURCE)
MODULE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MODULE)


class AuditExecutablePathTests(unittest.TestCase):
    def test_private_tmp_alias_preserves_identity_and_refuses_mismatch(self):
        with tempfile.TemporaryDirectory(prefix='neantik-alias-', dir='/private/tmp') as temp:
            executable = Path(temp) / 'NeAntik'
            executable.write_bytes(b'owned synthetic executable')
            alias = MODULE.audit_executable_path(executable)
            self.assertEqual(str(alias), '/tmp/' + str(executable)[len('/private/tmp/'):])
            self.assertTrue(alias.samefile(executable))
            with patch.object(MODULE.os.path, 'samefile', return_value=False):
                with self.assertRaisesRegex(ValueError, 'candidate-executable-alias-mismatch'):
                    MODULE.audit_executable_path(executable)
            with patch.object(MODULE, 'digest', side_effect=['first', 'second']):
                with self.assertRaisesRegex(ValueError, 'candidate-executable-alias-mismatch'):
                    MODULE.audit_executable_path(executable)
            link = Path(temp) / 'link'
            link.symlink_to(executable)
            with self.assertRaisesRegex(ValueError, 'candidate-executable-alias-mismatch'):
                MODULE.audit_executable_path(link)

    def test_non_private_tmp_path_retains_existing_behavior(self):
        path = Path('/Applications/NeAntik.app/Contents/MacOS/NeAntik')
        self.assertEqual(MODULE.audit_executable_path(path), path)


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
        # Socket shutdown publishes EOF before the watcher finishes recording
        # its receipt. EOF is not the ledger-completion synchronization point.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not any(
            e['kind'] == 'cut-active-local-channels' for e in self.fixture.ledger.events
        ):
            time.sleep(.01)
        self.assertTrue(any(e['kind'] == 'cut-active-local-channels' for e in self.fixture.ledger.events))
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

    def enable_https(self):
        self.assertTrue(self.fixture.close())
        self.fixture = MODULE.Fixture(Path(self.temp.name), owned_https=True)
        control = self.fixture.root / 'https-phase'
        control.write_text('proxy-success'); control.chmod(0o600)

    def test_https_is_opt_in_and_fixed_endpoint_has_bound_nonce_callback(self):
        with self.assertRaises(ValueError): self.fixture.https_url('proxy-success')
        self.enable_https()
        from urllib.parse import urlsplit, parse_qs
        url = urlsplit(self.fixture.https_url('proxy-success')); query = parse_qs(url.query)
        self.assertEqual(url.scheme, 'https'); self.assertEqual(url.hostname, 'browser.free')
        self.assertEqual(url.path, '/api/route-qa/https')
        self.assertEqual(len(query['nonce'][0]), 64)
        self.assertNotEqual(query['nonce'], parse_qs(urlsplit(self.fixture.https_url('direct-control')).query)['nonce'])
        self.assertEqual(query['callback'], ['http://127.0.0.1:' + str(self.fixture.origin.server_address[1]) + '/__neantik_route/ack'])

    def test_callback_admission_replay_uses_stub_not_browser_qualification(self):
        self.enable_https()
        with patch.object(MODULE, 'verify_https_receipt', return_value=True):
            target = '/__neantik_route/ack?r=fixture&s=fixture'
            self.assertTrue(self.fixture.https_callback(target, True))
            self.assertFalse(self.fixture.https_callback(target, True))
        hits = [e for e in self.fixture.ledger.events if e['kind'] == 'owned-https-receipt']
        self.assertEqual([e['valid'] for e in hits], [True, False])
        self.assertFalse(any('r' in e or 's' in e or 'nonce' in e for e in hits))

    def test_https_rejects_invalid_signature_missing_phase_and_unbounded_callback(self):
        self.enable_https()
        target = '/__neantik_route/ack?r=AAAA&s=AAAA'
        self.assertFalse(self.fixture.https_callback(target, True))
        self.assertFalse(self.fixture.https_callback('/__neantik_route/ack?' + 'x' * 4096, True))
        (self.fixture.root / 'https-phase').write_text('unknown-phase')
        self.assertFalse(self.fixture.https_callback(target, True))
        self.assertFalse(MODULE.verify_https_receipt({'r': ['a', 'b'], 's': ['c']}, 'a' * 64))

    def test_origin_dispatches_callback_before_http_route_phase_rejection(self):
        self.enable_https()
        port = self.fixture.origin.server_address[1]
        with patch.object(MODULE, 'verify_https_receipt', return_value=True):
            with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
                client.sendall(b'GET /__neantik_route/ack?r=fixture&s=fixture HTTP/1.1\r\n\r\n')
                self.assertTrue(MODULE.header(client).startswith(b'HTTP/1.1 200 '))
        with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
            client.sendall(b'GET /__neantik_route/ack?r=invalid&s=invalid HTTP/1.1\r\n\r\n')
            self.assertTrue(MODULE.header(client).startswith(b'HTTP/1.1 400 '))
        self.assertEqual([e['valid'] for e in self.fixture.ledger.events if e['kind'] == 'owned-https-receipt'], [True, False])

    def test_https_operator_control_rejects_symlink_public_mode_and_nonregular_file(self):
        self.enable_https(); control = self.fixture.root / 'https-phase'
        control.chmod(0o644); self.assertIsNone(self.fixture.https_phase())
        control.unlink(); target = self.fixture.root / 'other'; target.write_text('proxy-success'); target.chmod(0o600)
        control.symlink_to(target); self.assertIsNone(self.fixture.https_phase())
        control.unlink(); control.mkdir(); self.assertIsNone(self.fixture.https_phase())

    def test_https_refusal_and_cut_happen_before_outbound_connect(self):
        self.enable_https()
        auth = base64.b64encode((MODULE.QA_USER + ':' + MODULE.QA_PASSWORD).encode())
        for flag, expected in [('drop-upstream', b'HTTP/1.1 502 '), ('cut-upstream', b'')]:
            control = self.fixture.root / flag; control.touch()
            # The caller's own loopback connection is prepared before patching
            # the proxy's outward dial. This is transport gating, not TLS proof.
            with socket.create_connection(('127.0.0.1', self.fixture.proxy.server_address[1]), timeout=3) as client:
                with patch.object(MODULE.socket, 'create_connection', side_effect=AssertionError('outbound must not run')) as dial:
                    client.sendall(b'CONNECT browser.free:443 HTTP/1.1\r\nProxy-Authorization: Basic ' + auth + b'\r\n\r\n')
                    reply = client.recv(512)
                    self.assertTrue(reply.startswith(expected)); dial.assert_not_called()
            control.unlink()

    def test_node_receipt_oracle_has_real_crypto_positive_and_negative_controls(self):
        import json, shutil, subprocess
        if shutil.which('node') is None: self.skipTest('Node required for receipt crypto oracle')
        result = subprocess.run(['node', str(SOURCE.with_name('verify-owned-https-receipt.mjs')), '--self-test'],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), {'positiveControls': 1, 'negativeControls': 10, 'actualBrowser': False})


if __name__=='__main__': unittest.main()
