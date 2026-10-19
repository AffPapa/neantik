"""Real local TLS/CONNECT wire controls; not WebKit evidence."""
from pathlib import Path
import socket
import ssl
import tempfile
import unittest

import probe
import tls_fixture as fixture


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

    def connect(self, authority=None, auth=True):
        client = socket.create_connection(('127.0.0.1', self.tunnel.port), timeout=3)
        self.addCleanup(client.close)
        header = f'CONNECT {authority or fixture.NAME + ":443"} HTTP/1.1\r\n'.encode()
        if auth: header += b'Proxy-Authorization: ' + fixture.authorization('owned', 'fixture') + b'\r\n'
        client.sendall(header + b'\r\n')
        return client

    def context(self, root='ca'):
        return ssl.create_default_context(cafile=str(self.certificates / (root + '.pem')))

    def test_real_verified_tls_bytes_cross_tunnel(self):
        raw = self.connect(); self.assertIn(b'200 Connection Established', probe.read_header(raw))
        with self.context().wrap_socket(raw, server_hostname=fixture.NAME) as client:
            client.sendall(b'GET / HTTP/1.1\r\nHost: owned-tls.invalid\r\n\r\n')
            response = b''
            while chunk := client.recv(4096): response += chunk
        self.assertIn(b'<body>owned-tls-marker</body>', response)
        self.assertEqual(self.origin.snapshot()['responses'], 1)
        self.assertEqual(self.tunnel.snapshot()['authenticated'], 1)
        self.assertEqual(self.tunnel.authenticated_for(self.origin), 1)

    def test_wrong_hostname_fails_certificate_validation(self):
        raw = self.connect(); self.assertIn(b'200 Connection Established', probe.read_header(raw))
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.context().wrap_socket(raw, server_hostname='owned-wrong.invalid')
        self.assertEqual(self.origin.snapshot()['responses'], 0)

    def test_wrong_anchor_fails_certificate_validation(self):
        raw = self.connect(); self.assertIn(b'200 Connection Established', probe.read_header(raw))
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.context('wrong-ca').wrap_socket(raw, server_hostname=fixture.NAME)
        self.assertEqual(self.origin.snapshot()['responses'], 0)

    def test_challenge_does_not_connect_upstream(self):
        raw = self.connect(auth=False)
        self.assertIn(b'407 Proxy Authentication Required', probe.read_header(raw))
        self.assertEqual(self.origin.snapshot()['accepted'], 0)

    def test_unregistered_destination_cannot_open_tunnel(self):
        raw = self.connect(authority='foreign.invalid:443')
        self.assertEqual(raw.recv(4096), b'')
        self.assertEqual(self.origin.snapshot()['accepted'], 0)

    def test_arbitrary_destination_address_is_not_a_capability(self):
        with self.assertRaises(ValueError):
            fixture.Tunnel({fixture.NAME + ':443': ('127.0.0.1', self.origin.port)}, b'auth')


if __name__ == '__main__': unittest.main()
