"""Wire controls for the owned fixture, not WebKit or shipping evidence."""
import importlib.util
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('owned_webkit_probe', Path(__file__).with_name('probe.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)


class RuntimeManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.archive = Path(self.temp.name)
        self.receipt_root = self.archive / 'unpacked'; self.receipt_root.mkdir()
        self.root = self.receipt_root / 'Release'; self.root.mkdir()
        selected = {}
        for index in range(11):
            relative = f'bin/{index}'
            path = self.root / relative; path.parent.mkdir(exist_ok=True)
            path.write_bytes(f'fixture-{index}'.encode())
            selected[relative] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                  'minimumOSAndSDK': ['minos 15.4', 'sdk 26.5'],
                                  'architectures': ['arm64']}
        self.expected = 'a' * 64
        report = {'status': 'archive-inspected-not-executed', 'archiveSHA256': self.expected,
                  'sourceCommit': '43d5b8d85e2e5eed41d7ff8a79da831bf405be6c',
                  'root': str(self.receipt_root), 'selectedMachO': selected}
        (self.archive / 'extraction-inspection.json').write_text(json.dumps(report))

    def tearDown(self):
        self.temp.cleanup()

    def test_exact_archive_manifest_binds_arm64_hashes_and_minimum_os(self):
        result = probe.verify_runtime_manifest(self.archive, self.expected, '15.4')
        self.assertEqual(result['runtimeMinimumOS'], '15.4')
        self.assertEqual(result['selectedMachOCount'], 11)
        self.assertFalse(result['archiveNotarized'])

    def test_rejects_older_host_target_and_archive_hash_mismatch(self):
        with self.assertRaises(ValueError):
            probe.verify_runtime_manifest(self.archive, self.expected, '15.3')
        with self.assertRaises(ValueError):
            probe.verify_runtime_manifest(self.archive, 'b' * 64, '15.4')

    def test_rejects_binary_changed_after_extraction_receipt(self):
        (self.root / 'bin/0').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            probe.verify_runtime_manifest(self.archive, self.expected, '15.4')


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
