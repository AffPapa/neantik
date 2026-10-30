"""Real owned DNS/proxy controls; these do not qualify any browser runtime."""
import base64
from contextlib import closing
import importlib.util
import json
import http.client
from pathlib import Path
import socket
import struct
import ssl
import tempfile
import time
import unittest
from urllib.parse import urlsplit
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'runtime-network/controlled-dns-fixture.py'
SPEC = importlib.util.spec_from_file_location('controlled_dns_fixture', SOURCE)
MOD = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)


class DNSCodecTests(unittest.TestCase):
    def test_actual_wire_question_and_answer_preserve_id_question_and_zero_ttl(self):
        packet = MOD.query('Owned-1.neantik-dns.test', 1234)
        q = MOD.question(packet)
        self.assertEqual((q['identifier'], q['name'], q['kind']), (1234, 'owned-1.neantik-dns.test', 1))
        answer = MOD.reply(packet, known=True)
        result = MOD.question(answer, response=True)
        self.assertEqual(result['question'], q['question'])
        self.assertEqual((result['identifier'], result['rcode'], result['answers']), (1234, 0, 1))
        self.assertEqual(answer[-10:], b'\0\0\0\0\0\4\x7f\0\0\1')

    def test_nxdomain_servfail_and_non_a_nodata_are_distinct(self):
        packet = MOD.query('own.test', 7)
        for known, refused, expected in [(False, False, 3), (True, True, 2)]:
            answer = MOD.question(MOD.reply(packet, known=known, refused=refused), response=True)
            self.assertEqual((answer['rcode'], answer['answers']), (expected, 0))
        for kind in (28, 65):  # AAAA and HTTPS queries must not receive invented A data.
            other = packet[:-4] + struct.pack('!HH', kind, 1)
            result = MOD.question(MOD.reply(other, known=True), response=True)
            self.assertEqual((result['kind'], result['rcode'], result['answers']), (kind, 0, 0))

    def test_bounded_query_edns_is_accepted_but_not_echoed_as_an_answer(self):
        packet = MOD.query('own.test', 7)
        packet = packet[:10] + b'\0\1' + packet[12:] + b'\0' + struct.pack('!HHIH', 41, 1232, 0, 2) + b'\0\0'
        self.assertEqual(MOD.question(packet)['name'], 'own.test')
        self.assertEqual(MOD.question(MOD.reply(packet, known=True), response=True)['answers'], 1)
        with self.assertRaises(MOD.DNSMessageError): MOD.question(packet[:-1])

    def test_malformed_packets_never_become_a_successful_question(self):
        packet = MOD.query('own.test', 7)
        cases = [b'', packet[:16], packet + b'x', packet * 200,
                 packet[:4] + b'\0\2' + packet[6:],
                 packet[:6] + b'\0\1' + packet[8:],
                 packet[:12] + b'\xc0\x0c' + packet[-4:],
                 packet[:12] + b'\x40' + b'a'*64 + b'\0' + packet[-4:],
                 packet[:-2] + b'\0\3']
        for flag in (0x8000, 0x7800, 0x0200, 0x0400, 0x0080, 0x0040, 1):
            cases.append(packet[:2] + struct.pack('!H', flag) + packet[4:])
        for wrong in cases:
            with self.subTest(size=len(wrong), prefix=wrong[:6]):
                with self.assertRaises(MOD.DNSMessageError): MOD.question(wrong)
        # Deliberately broken label fixture catches a permissive ASCII range.
        for bad in ('o/n.test', 'o.n/.test', '-own.test', 'own-.test', 'o..test'):
            with self.subTest(name=bad):
                with self.assertRaises(MOD.DNSMessageError): MOD.query(bad, 7)
        with self.assertRaises(MOD.DNSMessageError): MOD.question(MOD.reply(packet, known=True))

    def test_malformed_answers_cannot_satisfy_upstream_resolver(self):
        good = MOD.reply(MOD.query('own.test', 8), known=True)
        for wrong in (good[:-1], good+b'x', good[:-16]+b'\0'+good[-15:],
                      good[:-10]+b'\0\0\0\1'+good[-6:]):
            with self.assertRaises(MOD.DNSMessageError): MOD.question(wrong, response=True)


class ControlledDNSFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-own-dns-test-')
        self.fixture = MOD.DNSFixture(Path(self.temp.name))

    def tearDown(self):
        self.assertTrue(self.fixture.close())
        self.temp.cleanup()

    def wire(self, packet):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel:
            channel.settimeout(2)
            channel.sendto(packet, self.fixture.dns.server_address)
            answer, sender = channel.recvfrom(MOD.MAX_PACKET+1)
            self.assertEqual(sender, self.fixture.dns.server_address)
            return MOD.question(answer, response=True)

    def request(self, phase, *, direct=False, target=None):
        f = self.fixture
        target = target or f.url(phase)
        parsed = urlsplit(target)
        with socket.create_connection(('127.0.0.1', f.origin.server_address[1] if direct else f.proxy.server_address[1]), timeout=3) as channel:
            channel.settimeout(3)
            auth = base64.b64encode((MOD.BASE.QA_USER+':'+MOD.BASE.QA_PASSWORD).encode())
            route = parsed.path+'?'+parsed.query if direct else target
            channel.sendall(b'GET '+route.encode()+b' HTTP/1.1\r\nHost: owned-fixture\r\nProxy-Authorization: Basic '+auth+b'\r\n\r\n')
            # A resolver failure deliberately closes, and cannot return a page.
            return channel.recv(16384)

    def wait_event(self, kind, count=1):
        until = time.monotonic()+2
        while time.monotonic()<until:
            events = [e for e in self.fixture.ledger.events if e['kind']==kind]
            if len(events)>=count: return events
            time.sleep(.01)
        self.fail('missing bounded fixture event: '+kind)

    def test_real_udp_server_handles_owned_unknown_and_malformed_queries(self):
        own = self.fixture.names['proxy-success']
        self.assertEqual(self.wire(MOD.query(own, 1))['answers'], 1)
        self.assertEqual(self.wire(MOD.query('unknown.test', 2))['rcode'], 3)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel:
            channel.settimeout(.15); channel.sendto(b'bad', self.fixture.dns.server_address)
            with self.assertRaises(socket.timeout): channel.recv(128)
        self.wait_event('dns-invalid-packet')
        events = self.wait_event('dns-wire', 2)
        self.assertEqual([e['phase'] for e in events], ['proxy-success', None])

    def test_invalid_hostname_mode_is_opt_in_for_dev_tls_scope(self):
        self.assertTrue(all(name.endswith('.neantik-dns.test') for name in self.fixture.names.values()))
        root = Path(self.temp.name) / 'invalid-qa'; root.mkdir(mode=0o700)
        dev = MOD.DNSFixture(root, name_suffix='.neantik-dns.invalid')
        try:
            self.assertTrue(all(name.endswith('.neantik-dns.invalid') for name in dev.names.values()))
            packet = MOD.query(dev.names['proxy-success'], 42)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel:
                channel.settimeout(2)
                channel.sendto(packet, dev.dns.server_address)
                answer, sender = channel.recvfrom(MOD.MAX_PACKET + 1)
            self.assertEqual(sender, dev.dns.server_address)
            self.assertEqual(MOD.question(answer, response=True)['answers'], 1)
        finally:
            self.assertTrue(dev.close())
        with self.assertRaises(ValueError):
            MOD.DNSFixture(root, name_suffix='.external.example')

    def test_actual_authenticated_proxy_resolves_over_udp_before_owned_origin_hit(self):
        self.assertTrue(self.request('proxy-recovered').startswith(b'HTTP/1.1 200 '))
        dns = self.wait_event('dns-wire')[0]
        origin = self.wait_event('origin')[0]
        self.assertEqual((dns['phase'], dns['transport'], dns['rcode']), ('proxy-recovered', 'udp', 0))
        self.assertTrue(origin['throughOwnedUpstream'])
        # Ledger emission is after sendto, so monotonic ordering of records is
        # not itself proof of packet order. An answer is required by the dial.
        self.assertFalse(any(e['kind']=='geoip-preflight-tunnel' for e in self.fixture.ledger.events))

    def test_dns_servfail_prevents_proxy_origin_hit_but_direct_control_exposes_bypass(self):
        flag = self.fixture.root/'fail-dns'; flag.touch()
        self.assertEqual(self.request('dns-refused'), b'')
        self.assertEqual(self.wait_event('dns-wire')[0]['rcode'], 2)
        self.wait_event('proxy-operation-failure')
        self.assertFalse(any(e['kind']=='origin' for e in self.fixture.ledger.events))
        # Intentional bypass succeeds even during DNS failure: sensitive control.
        self.assertTrue(self.request('direct-control', direct=True).startswith(b'HTTP/1.1 200 '))
        self.assertFalse(self.wait_event('origin')[0]['throughOwnedUpstream'])
        flag.unlink()
        self.assertTrue(self.request('proxy-recovered').startswith(b'HTTP/1.1 200 '))
        self.assertTrue(self.wait_event('origin', 2)[-1]['throughOwnedUpstream'])

    def test_unowned_destinations_wrong_ports_and_geoip_cannot_trigger_outward_dns(self):
        for target in ('http://unknown.test:80/', self.fixture.url('proxy-recovered').replace(
                ':'+str(self.fixture.origin.server_address[1])+'/', ':1/')):
            self.assertEqual(self.request('proxy-recovered', target=target), b'')
        with socket.create_connection(('127.0.0.1', self.fixture.proxy.server_address[1]), timeout=3) as client:
            auth = base64.b64encode((MOD.BASE.QA_USER+':'+MOD.BASE.QA_PASSWORD).encode())
            client.sendall(b'CONNECT ipapi.co:443 HTTP/1.1\r\nProxy-Authorization: Basic '+auth+b'\r\n\r\n')
            self.assertEqual(client.recv(256), b'')
        self.assertFalse(any(e['kind']=='dns-wire' for e in self.fixture.ledger.events))

    def test_dns_resolver_rejects_wrong_id_and_unexpected_answer_address(self):
        target = self.fixture.names['proxy-recovered']
        class Datagram:
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def settimeout(self, *_): pass
            def sendto(inner, packet, address): inner.packet = packet
            def recvfrom(inner, *_):
                answer = MOD.reply(inner.packet, known=True)
                if wrong == 'id': answer = bytes([answer[0]^1])+answer[1:]
                else: answer = answer[:-4]+b'\x7f\0\0\2'
                return answer, self.fixture.dns.server_address
        for wrong in ('id', 'address'):
            with patch.object(MOD.socket, 'socket', return_value=Datagram()):
                with self.assertRaises(OSError): self.fixture.open_upstream(target, self.fixture.origin.server_address[1])

    def test_shutdown_releases_dns_listener_and_threads(self):
        address = self.fixture.dns.server_address
        self.assertTrue(self.fixture.close())
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel: channel.bind(address)
        self.assertFalse(any(t.is_alive() for t in self.fixture.threads+[self.fixture.cut_thread]))

    def test_ledger_is_redacted_and_descriptor_is_explicitly_fixture_only(self):
        self.assertTrue(self.request('proxy-recovered').startswith(b'HTTP/1.1 200 '))
        self.wait_event('dns-wire'); self.wait_event('origin')
        data = json.dumps(self.fixture.ledger.events)
        for private in [*self.fixture.names.values(), MOD.BASE.QA_USER, MOD.BASE.QA_PASSWORD, '127.0.0.1']:
            self.assertNotIn(private, data)
        self.assertIn('no Chromium', self.fixture.description()['scope'])
        self.assertEqual((self.fixture.root/'observations.json').stat().st_mode & 0o777, 0o600)

    def test_public_or_symlink_roots_are_refused_before_binding(self):
        root = Path(self.temp.name)/'bad'; root.mkdir(mode=0o755); root.chmod(0o755)
        with self.assertRaises(ValueError): MOD.DNSFixture(root)
        link = Path(self.temp.name)/'link'; link.symlink_to(root, target_is_directory=True)
        with self.assertRaises(ValueError): MOD.DNSFixture(link)


class ControlledDoHFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cert_temp = tempfile.TemporaryDirectory(prefix='neantik-own-doh-cert-')
        cls.certificate, cls.key, cls.spki = MOD.own_certificate(cls.cert_temp.name)

    @classmethod
    def tearDownClass(cls): cls.cert_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-own-doh-test-')
        self.fixture = MOD.DNSOverHTTPSFixture(Path(self.temp.name), self.certificate, self.key, self.spki)
        self.context = ssl.create_default_context(cafile=str(self.certificate))

    def tearDown(self):
        self.assertTrue(self.fixture.close()); self.temp.cleanup()

    def request(self, method, path, body=None, headers=None):
        with closing(http.client.HTTPSConnection('127.0.0.1', self.fixture.doh.server_address[1],
                timeout=3, context=self.context)) as client:
            client.request(method, path, body=body, headers=headers or {})
            response = client.getresponse()
            return response.status, response.getheader('Content-Type'), response.read()

    def test_actual_tls_get_post_and_query_types_have_independent_redacted_receipts(self):
        name = self.fixture.names['direct-control']
        packet = MOD.query(name, 93)
        status, kind, body = self.request('POST', '/dns-query', packet, {'Content-Type': 'application/dns-message'})
        self.assertEqual((status, kind), (200, 'application/dns-message'))
        self.assertEqual(MOD.question(body, response=True)['answers'], 1)
        encoded = base64.urlsafe_b64encode(packet).decode().rstrip('=')
        status, _, body = self.request('GET', '/dns-query?dns='+encoded)
        self.assertEqual(status, 200)
        self.assertEqual(MOD.question(body, response=True)['identifier'], 93)
        other = packet[:-4]+struct.pack('!HH', 28, 1)
        status, _, body = self.request('POST', '/dns-query', other, {'Content-Type': 'application/dns-message'})
        self.assertEqual((status, MOD.question(body, response=True)['answers']), (200, 0))
        until = time.monotonic()+2
        while len([e for e in self.fixture.ledger.events if e['kind']=='dns-wire'])<3 and time.monotonic()<until: time.sleep(.01)
        events = [e for e in self.fixture.ledger.events if e['kind']=='dns-wire']
        self.assertEqual([e['transport'] for e in events], ['https']*3)
        self.assertNotIn(name, json.dumps(events))
        self.assertEqual(len(base64.b64decode(self.fixture.description()['testCertificateSPKI'])), 32)
        self.assertIn('not OS-default trust', self.fixture.description()['tlsBoundary'])

    def test_untrusted_tls_is_rejected_and_fixture_does_not_change_os_trust(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        with closing(http.client.HTTPSConnection('127.0.0.1', self.fixture.doh.server_address[1], timeout=3, context=context)) as client:
            with self.assertRaises(ssl.SSLCertVerificationError): client.request('GET', '/dns-query')
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.certificate.stat().st_mode & 0o777, 0o600)

    def test_doh_servfail_is_independent_of_upstream_udp_failure(self):
        packet = MOD.query(self.fixture.names['dns-refused'], 3)
        (self.fixture.root/'fail-dns').touch()
        self.assertEqual(MOD.question(self.request('POST', '/dns-query', packet,
            {'Content-Type': 'application/dns-message'})[-1], response=True)['rcode'], 0)
        (self.fixture.root/'fail-doh').touch()
        self.assertEqual(MOD.question(self.request('POST', '/dns-query', packet,
            {'Content-Type': 'application/dns-message'})[-1], response=True)['rcode'], 2)

    def test_bad_http_or_dns_request_cannot_receive_a_successful_dns_answer(self):
        packet = MOD.query(self.fixture.names['direct-control'], 1)
        cases = [('GET', '/foreign', None, {}, 404),
                 ('DELETE', '/dns-query', None, {}, 405),
                 ('POST', '/dns-query', packet, {'Content-Type': 'text/plain'}, 415),
                 ('POST', '/dns-query', b'bad', {'Content-Type': 'application/dns-message'}, 400)]
        for method, path, body, fields, status in cases:
            with self.subTest(method=method, path=path):
                self.assertEqual(self.request(method, path, body, fields)[0], status)
        # Header/body bounds reject before allocation of the advertised body.
        with socket.create_connection(self.fixture.doh.server_address, timeout=3) as raw:
            with self.context.wrap_socket(raw, server_hostname='127.0.0.1') as channel:
                channel.sendall(b'POST /dns-query HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n')
                self.assertEqual(channel.recv(128), b'')
        self.assertFalse(any(e['kind']=='dns-wire' for e in self.fixture.ledger.events))


if __name__ == '__main__': unittest.main()
