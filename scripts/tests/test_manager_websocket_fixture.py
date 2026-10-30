"""Real synthetic TCP/frame controls for the fixture; no browser qualification."""
import base64
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import unittest
from urllib.parse import urlsplit, urlencode

SPEC = importlib.util.spec_from_file_location('manager_ws_test', Path(__file__).resolve().parents[1] / 'runtime-network/manager-websocket-fixture.py')
F = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(F)


def masked(payload, opcode=1):
    key = b'own1'
    return bytes((0x80 | opcode, 0x80 | len(payload))) + key + bytes(x ^ key[i % 4] for i, x in enumerate(payload))


class ManagerWebSocketFixtureTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(prefix='neantik-ws-wire-'); self.f = F.ManagerWebSocketFixture(Path(self.root.name))
        self.f.peer_inspector = lambda channel, direct: dict(syntheticPeer=True, direct=direct)

    def tearDown(self):
        self.assertTrue(self.f.close()); self.root.cleanup()

    def connect(self, port, protected=True, auth=True):
        client = socket.create_connection(self.f.proxy.server_address if protected else ('127.0.0.1', port), timeout=3); client.settimeout(3)
        if protected:
            authorization = base64.b64encode((F.BASE.QA_USER + ':' + F.BASE.QA_PASSWORD).encode())
            client.sendall(b'CONNECT 127.0.0.1:' + str(port).encode() + b' HTTP/1.1\r\n' + (b'Proxy-Authorization: Basic ' + authorization + b'\r\n' if auth else b'') + b'\r\n')
            header = F.BASE.header(client)
            if not header.startswith(b'HTTP/1.1 200 '): return client, header
        return client, None

    def websocket(self, mode, phase, protected=True):
        client, refused = self.connect(self.f.websocket.server_address[1], protected)
        if refused is not None: return client, refused
        path = '/echo?' + urlencode(dict(mode=mode, nonce=self.f.nonces[mode], phase=phase))
        origin = 'http://127.0.0.1:' + str(self.f.origin.server_address[1])
        client.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: own\r\nOrigin: ' + origin + '\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + base64.b64encode(bytes(16)).decode() + '\r\n\r\n').encode())
        return client, F.BASE.header(client)

    def echo(self, client, mode, phase):
        payload = ('own:' + self.f.nonces[mode] + ':' + phase).encode(); client.sendall(masked(payload))
        self.assertEqual(F.read_exact(client, len(payload) + 2), F.frame(payload))

    def test_actual_echo_live_cut_refusal_and_same_endpoint_recovery(self):
        f = self.f; f.control('proxy-success', 'initial'); endpoint = f.proxy.server_address
        client, header = self.websocket('proxy-success', 'initial'); self.assertIn(b'101 Switching', header)
        self.echo(client, 'proxy-success', 'initial'); f.control('proxy-success', 'blocked')
        self.assertEqual(client.recv(128), b''); client.close()
        refused, header = self.websocket('proxy-success', 'blocked'); self.assertIn(b'502 Bad Gateway', header); refused.close()
        f.control('proxy-success', 'recovered'); client, header = self.websocket('proxy-success', 'recovered')
        self.assertIn(b'101 Switching', header); self.echo(client, 'proxy-success', 'recovered'); client.sendall(masked(b'\x03\xe8', 8)); self.assertEqual(F.read_exact(client, 4), F.frame(b'\x03\xe8', 8)); client.close()
        self.assertEqual(f.proxy.server_address, endpoint)
        self.assertEqual([e['phase'] for e in f.ledger.events if e['kind'] == 'ws-handshake'], ['initial', 'recovered'])
        self.assertTrue(all(e['peer']['route'] == 'proxy' for e in f.ledger.events if e['kind'] == 'ws-handshake'))

    def test_deliberate_direct_control_detects_route_bypass_and_survives_fault(self):
        f = self.f; f.completed.add('proxy-success'); f.control('direct-control', 'initial')
        client, header = self.websocket('direct-control', 'initial', False); self.assertIn(b'101 Switching', header)
        self.echo(client, 'direct-control', 'initial'); f.control('direct-control', 'blocked')
        # Existing Direct connection still exchanges the original phase data.
        self.echo(client, 'direct-control', 'initial')
        another, header = self.websocket('direct-control', 'blocked', False); self.assertIn(b'101 Switching', header)
        self.echo(another, 'direct-control', 'blocked'); client.close(); another.close()
        self.assertTrue(all(e['peer']['route'] == 'direct' for e in f.ledger.events if e['kind'] == 'ws-handshake'))

    def test_control_HTTP_stays_available_during_WS_refusal(self):
        f = self.f; f.control('proxy-success', 'initial')
        client, refused = self.connect(f.origin.server_address[1]); self.assertIsNone(refused)
        path = urlsplit(f.http_url('/control', 'proxy-success', phase='blocked')).path + '?' + urlsplit(f.http_url('/control', 'proxy-success', phase='blocked')).query
        client.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: own\r\n\r\n').encode()); self.assertIn(b'200 OK', F.BASE.header(client)); client.close()
        self.assertEqual(f.phase_name, 'blocked')

    def test_authentication_external_destination_and_unsafe_sequence_refuse(self):
        client, header = self.connect(self.f.websocket.server_address[1], auth=False); self.assertIn(b'407 Proxy', header); client.close()
        for mode, phase in [('direct-control', 'initial'), ('proxy-success', 'recovered'), ('wrong', 'initial')]:
            with self.assertRaises((ValueError, KeyError)): self.f.control(mode, phase)
        self.f.control('proxy-success', 'initial')
        with self.assertRaises(ValueError): self.f.control('proxy-success', 'initial')
        with socket.create_connection(self.f.proxy.server_address, timeout=3) as client:
            client.settimeout(3); auth = base64.b64encode((F.BASE.QA_USER + ':' + F.BASE.QA_PASSWORD).encode())
            client.sendall(b'CONNECT 127.0.0.1:9 HTTP/1.1\r\nProxy-Authorization: Basic ' + auth + b'\r\n\r\n')
            self.assertEqual(client.recv(32), b'')

    def test_frame_semantics_limits_and_partial_reads(self):
        class Channel:
            def __init__(self, value): self.value = io.BytesIO(value)
            def recv(self, size): return self.value.read(min(size, 1))
        self.assertEqual(F.client_frame(Channel(masked(b'hello'))), (1, b'hello'))
        self.assertEqual(F.client_frame(Channel(masked(b'\x03\xe8', 8))), (8, b'\x03\xe8'))
        for value in [b'', b'\x01\x80abcd', b'\x81\x01a', b'\x82\x80abcd', b'\x81\xfeabcd', masked(b'hello')[:-1]]:
            with self.assertRaises(ValueError): F.client_frame(Channel(value))
        with self.assertRaises(ValueError): F.frame(bytes(126))

    def test_nonce_result_shape_and_completion_do_not_export_payload(self):
        f = self.f
        value = dict(mode='proxy-success', rows=[], held=None, errors=['controlled failure'], remaining=0)
        self.assertEqual(F.validate_result(value, 'proxy-success'), value)
        for changed in [dict(value, mode='direct-control'), dict(value, remaining=True), dict(value, secret='forbidden'), dict(value, held={'actualURL':'forbidden'})]:
            with self.assertRaises((ValueError, KeyError)): F.validate_result(changed, 'proxy-success')
        for path in ['/owned-route?mode=proxy-success&nonce=wrong', '/owned-route?mode=proxy-success&nonce=' + f.nonces['proxy-success'] + '&extra=wrong']:
            with self.assertRaises(ValueError): f.parse(path, '/owned-route')


if __name__ == '__main__': unittest.main()
