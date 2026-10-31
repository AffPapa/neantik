"""Actual owned UDP/proxy/origin linkage; no browser claim from these tests."""
import base64
import os
import importlib.util
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

SOURCE = Path(__file__).resolve().parents[1] / 'runtime-network/manager-dns-fixture.py'
SPEC = importlib.util.spec_from_file_location('manager_dns_fixture_test', SOURCE)
MOD = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)


class ManagerDNSFixtureTests(unittest.TestCase):
    def test_partial_control_never_waits_for_newline_and_buffer_is_bounded(self):
        read,write=os.pipe();pending=bytearray()
        try:
            os.write(write,b'{');start=time.monotonic()
            self.assertEqual(MOD.DNS.BASE.read_control_lines(read,pending),[])
            self.assertLess(time.monotonic()-start,.2)
            self.assertEqual(pending,b'{')
            os.write(write,b'"action":"recover"}\n')
            self.assertEqual(MOD.DNS.BASE.read_control_lines(read,pending),[b'{"action":"recover"}'])
            os.write(write,b'a'*1025)
            with self.assertRaises(ValueError):MOD.DNS.BASE.read_control_lines(read,pending)
        finally:os.close(read);os.close(write)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-manager-dns-unit-')
        self.fixture = MOD.ManagerDNSFixture(Path(self.temp.name))

    def tearDown(self):
        self.assertTrue(self.fixture.close())
        self.temp.cleanup()

    def request(self, phase, *, proxy=True, connect=False, target=None, hostname_phase=None):
        f = self.fixture; url = urlsplit(f.url(phase)); path = url.path + '?' + url.query
        host = f.names[hostname_phase or phase] if proxy else '127.0.0.1'
        target = path if target is None else target
        auth = base64.b64encode((MOD.DNS.BASE.QA_USER+':'+MOD.DNS.BASE.QA_PASSWORD).encode())
        with socket.socket() as channel:
            channel.settimeout(4); channel.connect(('127.0.0.1', f.proxy.server_address[1] if proxy else f.origin.server_address[1]))
            if connect:
                channel.sendall(('CONNECT '+host+':'+str(f.origin.server_address[1])+' HTTP/1.1\r\nProxy-Authorization: Basic ').encode()+auth+b'\r\n\r\n')
                try: header=MOD.DNS.BASE.header(channel)
                except (ValueError,OSError): return b''
                if b'200 Connection Established' not in header: return header
            request_target = 'http://'+host+':'+str(f.origin.server_address[1])+target if proxy and not connect else target
            request=('GET '+request_target+' HTTP/1.1\r\nHost: '+host+'\r\nConnection: close\r\n').encode()
            if proxy and not connect: request+=b'Proxy-Authorization: Basic '+auth+b'\r\n'
            channel.sendall(request+b'\r\n'); result=b''
            while True:
                try: part=channel.recv(65536)
                except (ConnectionResetError,socket.timeout): break
                if not part: break
                result+=part
            return result

    def events(self, kind, phase=None):
        return [e for e in self.fixture.ledger.events if e['kind']==kind and (phase is None or e.get('phase')==phase)]

    def test_real_proxy_dns_refusal_direct_origin_control_and_recovery(self):
        self.assertIn(b'200 OK',self.request('proxy-success'))
        accepted=self.events('dns-resolution-accepted','proxy-success')[0]
        origin=self.events('origin','proxy-success')[0]
        self.assertEqual(accepted['requestID'],origin['requestID'])
        self.assertLess(accepted['at'],origin['at'])  # accepted answer, not UDP send/log scheduling
        self.assertEqual((accepted['faultEpoch'],accepted['requestEpoch'],accepted['rcode']),(0,0,0))
        state=self.fixture.apply_control('fail-dns');self.assertEqual(state['faultEpoch'],1)
        self.assertNotIn(b'200 OK',self.request('dns-refused'))
        denied=self.events('dns-resolution-rejected','dns-refused')[0]
        self.assertEqual((denied['faultEpoch'],denied['requestEpoch'],denied['rcode']),(1,1,2))
        self.assertFalse(self.events('origin','dns-refused'))
        self.assertIn(b'200 OK',self.request('direct-control',proxy=False))
        direct=self.events('origin','direct-control')[0]
        self.assertFalse(direct['throughOwnedUpstream']);self.assertTrue(direct['faultEnabled'])
        self.assertEqual(direct['faultEpoch'],1)
        self.fixture.apply_control('recover')
        self.assertIn(b'200 OK',self.request('proxy-recovered'))
        recovery=self.events('origin','proxy-recovered')[0]
        self.assertTrue(recovery['throughOwnedUpstream']);self.assertEqual(recovery['faultEpoch'],2)
        self.assertNotEqual(recovery['requestID'],origin['requestID'])

    def test_connect_tunnel_links_validated_dns_to_inner_http_request(self):
        self.assertIn(b'200 OK',self.request('proxy-success',connect=True))
        accepted=self.events('dns-resolution-accepted','proxy-success')[0]
        origin=self.events('origin','proxy-success')[0]
        self.assertEqual(accepted['requestID'],origin['requestID'])

    def test_direct_bypass_is_recorded_even_when_peer_handler_rejects_it(self):
        self.fixture.apply_control('fail-dns')
        self.fixture.peer_inspector=lambda *_: (_ for _ in ()).throw(ValueError('unowned'))
        self.assertNotIn(b'200 OK',self.request('dns-refused',proxy=False))
        arrivals=self.events('dns-origin-arrival','dns-refused')
        self.assertEqual(len(arrivals),1);self.assertFalse(arrivals[0]['throughOwnedUpstream'])
        self.assertTrue(arrivals[0]['faultEnabled']);self.assertFalse(self.events('origin','dns-refused'))

    def test_host_phase_mismatch_and_wrong_nonce_never_become_origin(self):
        self.assertNotIn(b'200 OK',self.request('dns-refused',hostname_phase='proxy-success'))
        self.assertNotIn(b'200 OK',self.request('dns-refused',hostname_phase='proxy-success',connect=True))
        self.assertNotIn(b'200 OK',self.request('proxy-success',target='/owned-route?phase=proxy-success&nonce=wrong'))
        self.assertFalse(self.events('origin'))

    def test_old_request_header_cannot_be_replayed_as_a_new_origin(self):
        self.assertIn(b'200 OK',self.request('proxy-success'))
        event=self.events('origin','proxy-success')[0]
        wire=('GET /owned-route HTTP/1.1\r\nX-NeAntik-Owned-Request: '+event['requestID']+'\r\n\r\n').encode()
        with self.assertRaises(ValueError):self.fixture.origin_observation(wire,'proxy-success',True)
        with self.assertRaises(ValueError):self.fixture.origin_observation(wire.replace(event['requestID'].encode(),b'a'*32),'proxy-success',True)

    def test_faults_require_operator_control_and_bounded_transitions(self):
        for value in ['stop','anything',None]:
            with self.assertRaises(ValueError):self.fixture.apply_control(value)
        self.assertEqual(self.fixture.apply_control('recover')['faultEpoch'],0)
        self.fixture.apply_control('fail-dns');self.fixture.apply_control('fail-dns')
        self.assertEqual([e['faultEpoch'] for e in self.events('dns-control')],[0,1])
        self.fixture.apply_control('recover')
        (self.fixture.root/'fail-dns').symlink_to(self.fixture.root/'missing')
        # exists() alone must not accept a dangling symlink as an absent control.
        self.assertFalse(self.fixture.control_snapshot()['controlConsistent'])
        with self.assertRaises(ValueError):self.fixture.apply_control('recover')
        with self.assertRaises((ValueError,OSError)):self.fixture.apply_control('fail-dns')

    def test_default_denies_external_preflight_opt_in_keeps_exact_allowlist(self):
        self.assertFalse(self.fixture.public_tls_hosts)
        with tempfile.TemporaryDirectory(prefix='neantik-dns-preflight-') as root:
            allowed=MOD.ManagerDNSFixture(Path(root),allow_manager_preflight=True)
            try:
                self.assertEqual(allowed.public_tls_hosts,frozenset({'ipapi.co','ipwho.is','free.freeipapi.com'}))
                self.assertNotIn('example.com',allowed.public_tls_hosts)
            finally:self.assertTrue(allowed.close())
        self.assertEqual(urlsplit(self.fixture.url('direct-control')).hostname,'127.0.0.1')
        self.assertEqual(self.fixture.navigation_phases(),MOD.PHASES)

    def test_no_raw_names_addresses_headers_or_credentials_in_redacted_events(self):
        import json
        self.assertIn(b'200 OK',self.request('proxy-success'))
        text=json.dumps(self.fixture.ledger.events)
        for secret in [self.fixture.names['proxy-success'],'127.0.0.1',MOD.DNS.BASE.QA_USER,MOD.DNS.BASE.QA_PASSWORD,'X-NeAntik']:
            self.assertNotIn(secret,text)

    def test_cli_rejects_mode_mixing_before_reading_app_or_starting_servers(self):
        cli=SOURCE.with_name('manager-route-fixture.py')
        for flags in [['--controlled-dns','--owned-https'],['--allow-manager-preflight']]:
            result=subprocess.run(['python3','-B',str(cli),'--app','/missing','--candidate-manifest','/missing','--output','/missing',*flags],capture_output=True,text=True)
            self.assertEqual(result.returncode,2);self.assertIn('preflight opt-in requires DNS mode',result.stderr)


if __name__=='__main__':unittest.main()
