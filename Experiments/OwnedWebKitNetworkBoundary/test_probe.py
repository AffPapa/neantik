"""Wire controls for the owned fixture, not WebKit or shipping evidence."""
import importlib.util
from pathlib import Path
import socket
import time
import unittest

spec = importlib.util.spec_from_file_location('owned_webkit_probe', Path(__file__).with_name('probe.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.endpoint = probe.Endpoint('127.0.0.1', 'owned-marker', auth=b'Basic b3duZWQ6Zml4dHVyZQ==',
                                       allowed=('owned.invalid:443',), path='/owned')

    def tearDown(self):
        self.assertTrue(self.endpoint.stop(), getattr(self.endpoint, 'last_stop_state', {}))

    def connect(self):
        connection = socket.create_connection(('127.0.0.1', self.endpoint.port), timeout=2)
        connection.settimeout(2)
        self.addCleanup(connection.close)
        return connection

    def test_challenge_then_valid_connect_returns_only_owned_marker(self):
        first = self.connect(); first.sendall(b'CONNECT owned.invalid:443 HTTP/1.1\r\n\r\n')
        self.assertIn(b'407 Proxy Authentication Required', probe.read_header(first))
        self.assertEqual(self.endpoint.snapshot()['responses'], 0)
        second = self.connect()
        second.sendall(b'CONNECT owned.invalid:443 HTTP/1.1\r\nProxy-Authorization: Basic b3duZWQ6Zml4dHVyZQ==\r\n\r\n')
        self.assertIn(b'200 Connection Established', probe.read_header(second))
        second.sendall(b'GET /owned HTTP/1.1\r\nHost: owned.invalid\r\n\r\n')
        body = b''
        while chunk := second.recv(4096):
            body += chunk
        self.assertIn(b'<body>owned-marker</body>', body)
        self.assertEqual(self.endpoint.snapshot()['authenticated'], 1)

    def test_wrong_credentials_never_receive_page(self):
        client = self.connect()
        client.sendall(b'CONNECT owned.invalid:443 HTTP/1.1\r\nProxy-Authorization: Basic wrong\r\n\r\n')
        self.assertIn(b'407 Proxy Authentication Required', probe.read_header(client))
        self.assertEqual(self.endpoint.snapshot()['responses'], 0)

    def test_cross_destination_is_closed_even_with_valid_auth(self):
        client = self.connect()
        client.sendall(b'CONNECT foreign.invalid:443 HTTP/1.1\r\nProxy-Authorization: Basic b3duZWQ6Zml4dHVyZQ==\r\n\r\n')
        self.assertEqual(client.recv(4096), b'')
        self.assertEqual(self.endpoint.snapshot()['authenticated'], 0)

    def test_refusing_listener_closes_connection(self):
        self.endpoint.refusing = True
        client = self.connect()
        self.assertEqual(client.recv(4096), b'')
        self.assertEqual(self.endpoint.snapshot()['responses'], 0)

    def test_stop_drains_an_incomplete_header(self):
        client = self.connect(); client.sendall(b'CONNECT ')
        deadline = time.monotonic() + 2
        while self.endpoint.snapshot()['accepted'] == 0 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.endpoint.snapshot()['accepted'], 1)
        self.assertTrue(self.endpoint.stop(), getattr(self.endpoint, 'last_stop_state', {}))


if __name__ == '__main__':
    unittest.main()
