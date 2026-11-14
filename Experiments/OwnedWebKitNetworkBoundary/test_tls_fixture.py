"""Real local TLS/CONNECT wire controls; not WebKit evidence."""
from pathlib import Path
import os
import socket
import ssl
import struct
import tempfile
import time
import unittest

import probe
import tls_fixture as fixture
import dns_tls_fixture
from turn_tcp_fixture import TurnTCPFixture


class TLSFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.certificates = fixture.certificates(Path(cls.temporary.name) / 'certificates', '127.0.0.1')

    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()

    def setUp(self):
        self.origin = fixture.TLSOrigin('127.0.0.1', 'owned-tls-marker', self.certificates)
        self.tunnel = fixture.Tunnel({fixture.NAME + ':443': self.origin}, fixture.authorization('owned', 'fixture'))

    def tearDown(self):
        self.assertTrue(self.tunnel.stop(), getattr(self.tunnel, 'last_stop_state', {}))
        self.assertTrue(self.origin.stop(), getattr(self.origin, 'last_stop_state', {}))

    def connect(self, authority=None, auth=True, tunnel=None):
        client = socket.create_connection(('127.0.0.1', (tunnel or self.tunnel).port), timeout=3)
        self.addCleanup(client.close)
        header = f'CONNECT {authority or fixture.NAME + ":443"} HTTP/1.1\r\n'.encode()
        if auth: header += b'Proxy-Authorization: ' + fixture.authorization('owned', 'fixture') + b'\r\n'
        client.sendall(header + b'\r\n')
        return client

    def context(self, root='ca'):
        context = ssl.create_default_context(cafile=str(self.certificates / (root + '.pem')))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        return context

    def test_real_verified_tls_bytes_cross_tunnel(self):
        raw = self.connect(); self.assertIn(b'200 Connection Established', probe.read_header(raw))
        with self.context().wrap_socket(raw, server_hostname=fixture.NAME) as client:
            client.sendall(b'GET / HTTP/1.1\r\nHost: owned-tls.invalid\r\n\r\n')
            response = b''
            while chunk := client.recv(4096): response += chunk
        self.assertIn(b'<body>owned-tls-marker</body>', response)
        self.assertEqual(self.origin.snapshot()['responses'], 1)
        self.assertEqual(self.origin.snapshot()['handshakeComplete'], 1)
        self.assertEqual(self.tunnel.snapshot()['authenticated'], 1)
        self.assertEqual(self.tunnel.authenticated_for(self.origin), 1)

    def test_final_route_counters_remain_readable_after_socket_teardown(self):
        self.assertTrue(self.tunnel.stop())
        self.assertTrue(self.origin.stop())
        self.assertEqual(self.tunnel.authenticated_for(self.origin), 0)
        self.assertEqual(self.tunnel.snapshot()['authenticated'], 0)
        self.assertEqual(self.origin.snapshot()['responses'], 0)

    def test_wrong_hostname_fails_certificate_validation(self):
        raw = self.connect(); self.assertIn(b'200 Connection Established', probe.read_header(raw))
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.context().wrap_socket(raw, server_hostname='owned-wrong.invalid')
        self.assertEqual(self.origin.snapshot()['responses'], 0)
        deadline = time.monotonic() + 2
        while self.origin.snapshot()['handshakeTLSFailure'] == 0 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.origin.snapshot()['handshakeTLSFailure'], 1)

    def test_wrong_anchor_fails_certificate_validation(self):
        raw = self.connect(); self.assertIn(b'200 Connection Established', probe.read_header(raw))
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.context('wrong-ca').wrap_socket(raw, server_hostname=fixture.NAME)
        self.assertEqual(self.origin.snapshot()['responses'], 0)

    def test_challenge_does_not_connect_upstream(self):
        raw = self.connect(auth=False)
        self.assertIn(b'407 Proxy Authentication Required', probe.read_header(raw))
        self.assertEqual(self.origin.snapshot()['accepted'], 0)

    def test_ambiguous_connect_headers_do_not_dial(self):
        for suffix in (b'Proxy-Authorization: duplicate\r\n\r\n',
                       b'Content-Length: 1\r\n\r\nx',
                       b'Host: foreign.invalid:443\r\n\r\n'):
            with socket.create_connection(('127.0.0.1', self.tunnel.port), timeout=3) as raw:
                raw.sendall(b'CONNECT owned-tls.invalid:443 HTTP/1.1\r\nProxy-Authorization: '
                            + fixture.authorization('owned', 'fixture') + b'\r\n' + suffix)
                self.assertEqual(raw.recv(1024), b'')
        self.assertEqual(self.origin.snapshot()['accepted'], 0)

    def test_unregistered_destination_cannot_open_tunnel(self):
        raw = self.connect(authority='foreign.invalid:443')
        self.assertEqual(raw.recv(4096), b'')
        self.assertEqual(self.origin.snapshot()['accepted'], 0)

    def test_arbitrary_destination_address_is_not_a_capability(self):
        with self.assertRaises(ValueError):
            fixture.Tunnel({fixture.NAME + ':443': ('127.0.0.1', self.origin.port)}, b'auth')
        with self.assertRaises(ValueError):
            fixture.Tunnel({}, b'auth', turn_target=('127.0.0.1', self.origin.port))

    @unittest.skipUnless(os.environ.get('NEANTIK_TURN_TEST_BINARY'), 'explicit Pion fixture executable required')
    def test_verified_turn_tls_binding_crosses_authorized_tunnel(self):
        with tempfile.TemporaryDirectory(prefix='neantik-turn-tls-wire-') as directory:
            tls_root = fixture.certificates(Path(directory).resolve() / 'turn', '127.0.0.1', TurnTCPFixture.host)
            certificate, key = tls_root / 'leaf.pem', tls_root / 'leaf.key'
            certificate.chmod(0o600)
            child = TurnTCPFixture(Path(os.environ['NEANTIK_TURN_TEST_BINARY']), tls_root,
                                   tls_files=(certificate, key))
            self.addCleanup(lambda: child.stop() if child.process.poll() is None else None)
            tunnel = fixture.Tunnel({}, fixture.authorization('owned', 'fixture'), turn_target=child)
            self.addCleanup(lambda: self.assertTrue(tunnel.stop()))
            self.assertEqual(child.browser_config()['url'], f'turns:{child.authority}?transport=tcp')
            self.assertEqual(child.browser_config(outage=True)['url'], child.browser_config()['url'])
            for ca, hostname in (('wrong-ca', child.host), ('ca', 'wrong-neantik.invalid')):
                with self.connect(authority=child.authority, tunnel=tunnel) as raw:
                    self.assertIn(b'200 Connection Established', probe.read_header(raw))
                    context = ssl.create_default_context(cafile=str(tls_root / f'{ca}.pem'))
                    context.minimum_version = ssl.TLSVersion.TLSv1_2
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        context.wrap_socket(raw, server_hostname=hostname)
            with self.connect(authority=child.authority, tunnel=tunnel) as raw:
                self.assertIn(b'200 Connection Established', probe.read_header(raw))
                context = ssl.create_default_context(cafile=str(tls_root / 'ca.pem'))
                context.minimum_version = ssl.TLSVersion.TLSv1_2
                with context.wrap_socket(raw, server_hostname=child.host) as secured:
                    transaction = os.urandom(12)
                    secured.sendall(struct.pack('!HHI12s', 1, 0, 0x2112A442, transaction))
                    with secured.makefile('rb') as stream:
                        response = stream.read(20)
                    self.assertEqual(struct.unpack('!HHI12s', response)[0::3], (0x0101, transaction))
            tunnel.set_turn_outage(True)
            with self.connect(authority=child.authority, tunnel=tunnel) as raw:
                self.assertIn(b'502 Bad Gateway', probe.read_header(raw))
            self.assertEqual(tunnel.turn_outage_count(), 1)
            self.assertEqual(tunnel.authenticated_turn_count(), 3)
            counts = child.stop()
            self.assertEqual((counts['allocations'], counts['tcpAccepts']), (0, 3))
            if 'tlsAccepted' in counts:
                self.assertEqual(counts['tlsAccepted'], 1)
                self.assertEqual(counts['tlsCertificateRejected'] + counts['tlsOtherFailure'], 2)

    @unittest.skipUnless(os.environ.get('NEANTIK_TURN_TEST_BINARY'), 'explicit Pion fixture executable required')
    def test_real_turn_control_crosses_only_the_exact_authorized_tunnel(self):
        with tempfile.TemporaryDirectory(prefix='neantik-turn-wire-') as directory:
            child = TurnTCPFixture(Path(os.environ['NEANTIK_TURN_TEST_BINARY']), Path(directory).resolve())
            self.addCleanup(lambda: child.stop() if child.process.poll() is None else None)
            dns_calls = []
            tunnel = fixture.Tunnel({}, fixture.authorization('owned', 'fixture'),
                                    dns_validator=lambda *args: dns_calls.append(args), turn_target=child)
            self.addCleanup(lambda: self.assertTrue(tunnel.stop()))
            with self.connect(authority=child.authority, auth=False, tunnel=tunnel) as raw:
                self.assertIn(b'407 Proxy Authentication Required', probe.read_header(raw))
            with self.connect(authority=f'foreign.invalid:{child.port}', tunnel=tunnel) as raw:
                self.assertEqual(raw.recv(1024), b'')
            self.assertEqual(tunnel.authenticated_turn_count(), 0)
            with self.connect(authority=child.authority, tunnel=tunnel) as raw:
                self.assertIn(b'200 Connection Established', probe.read_header(raw))
                transaction = os.urandom(12)
                raw.sendall(struct.pack('!HHI12s', 1, 0, 0x2112A442, transaction))
                with raw.makefile('rb') as stream:
                    response = stream.read(20)
                self.assertEqual(struct.unpack('!HHI12s', response)[0::3], (0x0101, transaction))
            self.assertEqual(tunnel.authenticated_turn_count(), 1)
            self.assertEqual(dns_calls, [])
            tunnel.set_turn_outage(True)
            with self.connect(authority=child.direct_canary_authority, auth=False, tunnel=tunnel) as raw:
                self.assertIn(b'407 Proxy Authentication Required', probe.read_header(raw))
            self.assertEqual(tunnel.turn_outage_count(), 0)
            with self.connect(authority=child.direct_canary_authority, tunnel=tunnel) as raw:
                self.assertIn(b'502 Bad Gateway', probe.read_header(raw))
            self.assertEqual(tunnel.turn_outage_count(), 1)
            self.assertEqual(tunnel.authenticated_turn_count(), 1)
            tunnel.set_turn_outage(False)
            with socket.create_connection(('127.0.0.1', child.port), timeout=3) as direct:
                transaction = os.urandom(12)
                direct.sendall(struct.pack('!HHI12s', 1, 0, 0x2112A442, transaction))
                with direct.makefile('rb') as stream:
                    response = stream.read(20)
                self.assertEqual(struct.unpack('!HHI12s', response)[0::3], (0x0101, transaction))
            nonce = 'c' * 32
            token = 'd' * 32
            origin = fixture.TLSOrigin('127.0.0.1', dns_tls_fixture.persistence_page(nonce),
                                       self.certificates, persistence_nonce=nonce)
            self.addCleanup(lambda: self.assertTrue(origin.stop()))
            origin.arm_turn_probe(child, token)
            with self.assertRaises(ValueError):
                origin.arm_turn_probe(child, 'e' * 32)

            def get(path):
                with socket.create_connection(('127.0.0.1', origin.port), timeout=3) as raw:
                    with self.context().wrap_socket(raw, server_hostname=fixture.NAME) as connection:
                        connection.sendall(f'GET {path} HTTP/1.1\r\nHost: owned-tls.invalid\r\n\r\n'.encode())
                        with connection.makefile('rb') as stream:
                            return stream.read()

            self.assertIn(b'probeOwnedTURN', get('/'))
            self.assertEqual(get('/qa-turn/' + 'e' * 32 + '/relay-nonce-delivered'), b'')
            self.assertEqual(get(f'/qa-turn/{token}/arbitrary-status'), b'')
            self.assertIn(b'ack', get(f'/qa-turn/{token}/relay-nonce-delivered'))
            trace = origin.snapshot()['requestTrace']
            self.assertEqual([row['category'] for row in trace],
                             ['page', 'unrecognized', 'unrecognized', 'turn-relay-nonce-delivered'])
            self.assertNotIn(token, repr(trace))
            self.assertNotIn(child.browser_config()['credential'], repr(trace))
            counts = child.stop()
            self.assertEqual(counts['allocations'], 0)
            if 'tcpAccepts' in counts:
                self.assertEqual(counts['tcpAccepts'], 2)
            with self.connect(authority=child.authority, tunnel=tunnel) as raw:
                self.assertEqual(raw.recv(1024), b'')
            self.assertEqual(tunnel.authenticated_turn_count(), 1)

    def test_origin_distinguishes_proxied_and_direct_https_connections(self):
        origin = fixture.TLSOrigin('127.0.0.1', 'route-control', self.certificates,
                                   persistence_nonce='b' * 32, attribute_routes=True)
        self.addCleanup(lambda: self.assertTrue(origin.stop()))
        tunnels = []
        for route in ('A', 'B'):
            tunnel = fixture.Tunnel({fixture.NAME + ':443': origin},
                                    fixture.authorization('owned', 'fixture'), route=route)
            tunnels.append(tunnel)
            self.addCleanup(lambda tunnel=tunnel: self.assertTrue(tunnel.stop()))
        for tunnel in (*tunnels, None):
            if tunnel is None:
                raw = socket.create_connection(('127.0.0.1', origin.port), timeout=3)
            else:
                raw = self.connect(tunnel=tunnel)
                self.assertIn(b'200 Connection Established', probe.read_header(raw))
            with self.context().wrap_socket(raw, server_hostname=fixture.NAME) as client:
                client.sendall(b'GET / HTTP/1.1\r\nHost: owned-tls.invalid\r\n\r\n')
                with client.makefile('rb') as stream:
                    self.assertIn(b'route-control', stream.read())
        self.assertEqual([row['route'] for row in origin.snapshot()['requestTrace']],
                         ['A', 'B', 'unattributed'])
        # A client can reach the origin and disconnect without sending HTTP.
        with socket.create_connection(('127.0.0.1', origin.port), timeout=3) as raw:
            raw.shutdown(socket.SHUT_WR)
            self.assertEqual(raw.recv(1024), b'')
        counts = origin.snapshot()
        self.assertEqual(counts['unattributedConnections'], 2)
        self.assertEqual(len(counts['requestTrace']), 3)

    def test_persistence_ack_is_scoped_to_own_nonce_and_state(self):
        nonce = 'b' * 32
        origin = fixture.TLSOrigin('127.0.0.1', dns_tls_fixture.persistence_page(nonce),
                                   self.certificates, persistence_nonce=nonce, click_probe=True)
        self.addCleanup(lambda: self.assertTrue(origin.stop()))

        def get(path):
            with socket.create_connection(('127.0.0.1', origin.port), timeout=3) as raw:
                with self.context().wrap_socket(raw, server_hostname=fixture.NAME) as client:
                    client.sendall(f'GET {path} HTTP/1.1\r\nHost: owned-tls.invalid\r\n\r\n'.encode())
                    answer = b''
                    while chunk := client.recv(4096): answer += chunk
                    return answer

        self.assertIn(b'NEANTIK_QA_TLS_PERSIST_RESTORED', get('/'))
        self.assertIn(b'ack', get(f'/qa-state/{nonce}/initial'))
        self.assertIn(b'ack', get(f'/qa-state/{nonce}/restored'))
        self.assertEqual(get('/qa-state/' + 'a' * 32 + '/restored'), b'')
        counts = origin.snapshot()
        self.assertEqual((counts['pageResponses'], counts['stateInitial'],
                          counts['stateRestored']), (1, 1, 1))
        self.assertEqual(counts['responses'], 3)
        trace = counts['requestTrace']
        self.assertEqual([event['category'] for event in trace],
                         ['page', 'initial', 'restored', 'unrecognized'])
        self.assertEqual([event['result'] for event in trace],
                         ['responded', 'responded', 'responded', 'refused'])
        self.assertEqual(trace[0]['fetchDestination'], 'missing')
        self.assertTrue(all(set(event) == {'atMonotonicNs', 'category', 'result'}
                            for event in trace[1:]))
        self.assertIn(b'ack', get(f'/qa-peer/{nonce}/absent/created'))
        self.assertEqual(get(f'/qa-peer/{nonce}/private/created'), b'')
        self.assertEqual(get('/qa-peer/' + 'a' * 32 + '/absent/created'), b'')
        updated = origin.snapshot()
        self.assertEqual(updated['requestTrace'][-3]['category'], 'peer-absent-created')
        self.assertEqual((updated['pageResponses'], updated['stateInitial'], updated['stateRestored']), (1, 1, 1))
        self.assertIn(b'ack', get(f'/qa-gpu/{nonce}/adapter'))
        self.assertEqual(get(f'/qa-gpu/{nonce}/private'), b'')
        self.assertEqual(get('/qa-gpu/' + 'a' * 32 + '/adapter'), b'')
        self.assertEqual(origin.snapshot()['requestTrace'][-3]['category'], 'gpu-adapter')

        self.assertIn(b'ack', get(f'/qa-click/{nonce}/trusted'))
        self.assertIn(b'ack', get(f'/qa-click/{nonce}/untrusted'))
        self.assertEqual(get('/qa-click/' + 'a' * 32 + '/trusted'), b'')
        self.assertEqual(get(f'/qa-click/{nonce}/unknown'), b'')
        self.assertEqual([entry['category'] for entry in origin.snapshot()['requestTrace'][-4:]],
                         ['click-trusted', 'click-untrusted', 'unrecognized', 'unrecognized'])

    def test_fetch_destination_is_bounded_and_never_returns_raw_headers(self):
        self.assertEqual(fixture.fetch_destination(b'GET / HTTP/1.1\r\nSec-Fetch-Dest: iframe\r\n\r\n'), 'iframe')
        self.assertEqual(fixture.fetch_destination(b'GET / HTTP/1.1\r\nSec-Fetch-Dest: document\r\n\r\n'), 'document')
        self.assertEqual(fixture.fetch_destination(b'GET / HTTP/1.1\r\nSec-Fetch-Dest: private-value\r\n\r\n'), 'other')
        self.assertEqual(fixture.fetch_destination(b'GET / HTTP/1.1\r\nSec-Fetch-Dest: iframe\r\nSec-Fetch-Dest: document\r\n\r\n'), 'ambiguous')


class DNSBackedTLSFixtureTests(unittest.TestCase):
    """One local DNS + HTTPS tunnel stage; no browser or Keychain is launched."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='neantik-dns-tls-wire-')
        self.root = Path(self.temporary.name)
        self.dns = dns_tls_fixture.DNS.DNSFixture(self.root,
                                                  name_suffix='.neantik-dns.invalid')
        self.name = self.dns.names['proxy-success']
        self.certificates = fixture.certificates(self.root / 'certificates', '127.0.0.1', self.name)
        self.origin = fixture.TLSOrigin('127.0.0.1', 'owned-dns-tls-marker', self.certificates)
        self.direct_b = fixture.TLSOrigin('127.0.0.1', 'independent-direct-b', self.certificates)
        self.validator = dns_tls_fixture.OwnedDNSValidator(self.dns, self.name, self.origin)
        self.authority = f'{self.name}:{self.origin.port}'
        self.tunnel = fixture.Tunnel({self.authority: self.origin},
                                     fixture.authorization('own-qa', 'synthetic'),
                                     dns_validator=self.validator)

    def tearDown(self):
        self.assertTrue(self.tunnel.stop())
        self.assertTrue(self.origin.stop())
        self.assertTrue(self.direct_b.stop())
        self.assertTrue(self.dns.close())
        self.temporary.cleanup()

    def connect(self, *, auth=True):
        client = socket.create_connection(('127.0.0.1', self.tunnel.port), timeout=3)
        client.settimeout(3)
        request = f'CONNECT {self.authority} HTTP/1.1\r\n'.encode()
        if auth:
            request += b'Proxy-Authorization: ' + fixture.authorization('own-qa', 'synthetic') + b'\r\n'
        client.sendall(request + b'\r\n')
        return client

    def trusted_request(self, raw, *, name=None, anchor='ca'):
        context = ssl.create_default_context(cafile=str(self.certificates / (anchor + '.pem')))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        with context.wrap_socket(raw, server_hostname=name or self.name) as client:
            client.sendall(b'GET / HTTP/1.1\r\nHost: owned-qa\r\n\r\n')
            response = b''
            while chunk := client.recv(4096): response += chunk
            return response

    def test_dns_answer_required_before_authenticated_https_and_new_client_recovery(self):
        raw = self.connect()
        self.assertIn(b'200 Connection Established', probe.read_header(raw))
        self.assertIn(b'owned-dns-tls-marker', self.trusted_request(raw))
        self.assertEqual(self.validator.snapshot(), {'accepted': 1, 'refused': 0})
        self.assertEqual(self.origin.snapshot()['responses'], 1)
        self.assertEqual(self.tunnel.authenticated_for(self.origin), 1)
        self.assertTrue(any(e['kind'] == 'dns-wire' and e['transport'] == 'udp'
                            and e['phase'] == 'proxy-success' and e['rcode'] == 0
                            for e in self.dns.ledger.events))

        # This is a new client connection, not a browser process restart.
        (self.root / 'fail-dns').touch()
        with self.connect() as refused:
            self.assertIn(b'502 Bad Gateway', probe.read_header(refused))
        self.assertEqual(self.origin.snapshot()['responses'], 1)
        self.assertEqual(self.validator.snapshot(), {'accepted': 1, 'refused': 1})
        (self.root / 'fail-dns').unlink()
        raw = self.connect()
        self.assertIn(b'200 Connection Established', probe.read_header(raw))
        self.assertIn(b'owned-dns-tls-marker', self.trusted_request(raw))
        self.assertEqual(self.validator.snapshot(), {'accepted': 2, 'refused': 1})

    def test_wrong_host_and_wrong_anchor_never_return_https_page(self):
        for name, anchor in [('wrong-qa.invalid', 'ca'), (self.name, 'wrong-ca')]:
            with self.subTest(name=name, anchor=anchor):
                raw = self.connect()
                self.assertIn(b'200 Connection Established', probe.read_header(raw))
                with self.assertRaises(ssl.SSLCertVerificationError):
                    self.trusted_request(raw, name=name, anchor=anchor)
        self.assertEqual(self.origin.snapshot()['responses'], 0)

    def test_auth_refusal_never_resolves_and_direct_b_remains_independent(self):
        with self.connect(auth=False) as refused:
            self.assertIn(b'407 Proxy Authentication Required', probe.read_header(refused))
        self.assertEqual(self.validator.snapshot(), {'accepted': 0, 'refused': 0})
        self.assertEqual(self.origin.snapshot()['accepted'], 0)
        with socket.create_connection(('127.0.0.1', self.direct_b.port), timeout=3) as raw:
            self.assertIn(b'independent-direct-b', self.trusted_request(raw))
        self.assertEqual(self.direct_b.snapshot()['responses'], 1)
        self.assertEqual(self.origin.snapshot()['responses'], 0)

    def test_certificate_names_reject_external_or_injected_dns_hosts(self):
        for name in ('foreign.invalid', 'a.neantik-dns.test', 'a' * 32 + '.other.test',
                     'a' * 32 + '.neantik-dns.test\nsubjectAltName=DNS:foreign.invalid'):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    fixture.certificates(self.root / 'invalid', '127.0.0.1', name)


class OwnedDNSReplyTests(unittest.TestCase):
    def test_profile_restart_page_requires_random_nonce_and_both_storage_types(self):
        page = dns_tls_fixture.persistence_page('a' * 32)
        self.assertIn('NEANTIK_QA_TLS_PERSIST_INITIAL', page)
        self.assertIn('NEANTIK_QA_TLS_PERSIST_RESTORED', page)
        self.assertIn('localStorage.getItem', page)
        self.assertIn('document.cookie', page)
        self.assertIn('fetch("/qa-state/"+value', page)
        for invalid in ('', 'a' * 31, 'a' * 32 + '"<script>', 'A' * 32):
            with self.assertRaises(ValueError):
                dns_tls_fixture.persistence_page(invalid)

    def test_wrong_id_name_address_or_source_cannot_authorize_tls_connect(self):
        name = 'a' * 32 + '.neantik-dns.invalid'
        server = ('127.0.0.1', 53123)
        packet = dns_tls_fixture.DNS.query(name, 17)
        answer = dns_tls_fixture.DNS.reply(packet, known=True)
        check = lambda response, sender=server, identifier=17, expected=name: (
            dns_tls_fixture.reply_matches(response, sender, server=server,
                                          identifier=identifier, name=expected,
                                          address='127.0.0.1'))
        self.assertTrue(check(answer))
        self.assertFalse(check(answer, ('127.0.0.1', 53124)))
        self.assertFalse(check(answer, identifier=18))
        self.assertFalse(check(answer, expected='b' * 32 + '.neantik-dns.invalid'))
        self.assertFalse(check(answer[:-4] + b'\x7f\0\0\2'))
        self.assertFalse(check(answer[:-1]))


if __name__ == '__main__': unittest.main()
