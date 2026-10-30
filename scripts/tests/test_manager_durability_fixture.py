"""Own protocol/model controls; not actual browser data durability evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'runtime-network'
SPEC = importlib.util.spec_from_file_location('durability_fixture_test', ROOT / 'manager-durability-fixture.py')
F = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(F)
C_SPEC = importlib.util.spec_from_file_location('durability_collector_test', ROOT / 'collect-manager-durability.py')
C = importlib.util.module_from_spec(C_SPEC); C_SPEC.loader.exec_module(C)


def result(phase, marker):
    expected = {key: marker for key in F.KEYS}
    if phase == 'read': expected['sessionStorage'] = None
    return dict(phase=phase, before={key: None for key in F.KEYS} if phase == 'write' else dict(expected), after=dict(expected),
                errors=[], wrote=phase == 'write', strictIDB=phase == 'write')


class ManagerDurabilitySchemaTests(unittest.TestCase):
    def test_write_read_and_loss_repair_or_secret_controls(self):
        for phase in ('write', 'read'):
            value = result(phase, 'owned'); reduced = F.validate_result(value, phase, 'owned')
            self.assertTrue(reduced['allPersistentValuesMatch']); self.assertNotIn('owned', json.dumps(reduced))
            changes = [lambda v: v.update(secret='forbidden'), lambda v: v.update(errors=['timeout']), lambda v: v['after'].update(cookie=None),
                       lambda v: v['after'].update(indexedDB='other'), lambda v: v.update(wrote=not v['wrote']), lambda v: v['after'].update(localStorage=False)]
            changes += [lambda v: v.update(strictIDB=False), lambda v: v['before'].update(cookie='owned')] if phase == 'write' else [lambda v: v['after'].update(sessionStorage='owned'), lambda v: v['before'].update(cacheStorage=None)]
            for index, change in enumerate(changes):
                broken = copy.deepcopy(value); change(broken)
                with self.subTest(phase=phase, index=index), self.assertRaises(ValueError): F.validate_result(broken, phase, 'owned')

    def test_normal_exit_parser_requires_both_real_manager_records(self):
        text = 'now browser_launch version=own\nnow browser_exit reason=1 status=0\n' * 2
        self.assertEqual(C.normal_exits(text, 'own')['exits'], [dict(reason=1, status=0)] * 2)
        for altered in [text[:len(text)//2], text + text, text.replace('own', 'wrong'), text.replace('browser_exit', 'absent')]:
            with self.assertRaises(ValueError): C.normal_exits(altered, 'own')

    def test_wrong_or_ambiguous_capture_mode_refuses_before_native_inspection(self):
        for args in [dict(manager_durability=True, manager_websocket=True), dict(manager_durability=True, manager_webrtc=True)]:
            with self.assertRaises(ValueError): C.CORE.capture({}, Path('/unused'), 'direct-control', **args)
        with self.assertRaises(ValueError): C.capture({}, Path('/unused'), 'wrong')
        with self.assertRaises(ValueError): C.CORE.capture({'durabilityFixture': {'mode': 'manager-data-durability'}}, Path('/unused'), 'proxy-success', manager_durability=True)


class ManagerDurabilityWireTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-durability-wire-'); self.f = F.ManagerDurabilityFixture(Path(self.temp.name))
        self.f.peer_inspector = lambda channel, direct: dict(syntheticPeer=True, direct=direct)

    def tearDown(self): self.assertTrue(self.f.close()); self.temp.cleanup()

    def request(self, method, path, body=b''):
        with socket.create_connection(self.f.origin.server_address, timeout=3) as client:
            client.settimeout(3); client.sendall(method + b' ' + path.encode() + b' HTTP/1.1\r\nHost: own\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
            header = F.BASE.header(client); payload = bytearray()
            try:
                while chunk := client.recv(16384): payload.extend(chunk)
            except ConnectionResetError:
                # An early protocol refusal need not drain an invalid POST
                # body. Accept reset only AFTER its complete400 header; a
                # reset during success or before a response remains a failure.
                if not header.startswith(b'HTTP/1.1 400 '): raise
            return header, bytes(payload)

    def test_same_startup_URL_write_then_read_without_repair(self):
        f = self.f; page = '/owned-data?nonce=' + f.nonce; receipt = '/owned-receipt?nonce=' + f.nonce
        for phase in ('write', 'read'):
            header, body = self.request(b'GET', page); self.assertIn(b'200 OK', header); self.assertIn(('"phase": "' + phase + '"').encode(), body)
            header, _ = self.request(b'POST', receipt, json.dumps(result(phase, f.marker)).encode()); self.assertIn(b'200 OK', header)
        observations = [event for event in f.ledger.events if event['kind'] == 'durability-result']
        self.assertEqual([e['phase'] for e in observations], ['write', 'read']); self.assertNotIn(f.marker, json.dumps(observations))
        self.assertNotIn(f.nonce, json.dumps(observations)); self.assertFalse(observations[1]['wrote'])

    def test_bad_nonce_duplicate_early_receipt_and_missing_custody_refuse(self):
        f = self.f; page = '/owned-data?nonce=' + f.nonce; receipt = '/owned-receipt?nonce=' + f.nonce
        self.assertIn(b'400 Bad', self.request(b'GET', '/owned-data?nonce=wrong')[0])
        self.assertIn(b'400 Bad', self.request(b'POST', receipt, json.dumps(result('write', f.marker)).encode())[0])
        self.assertIn(b'200 OK', self.request(b'GET', page)[0]); self.assertIn(b'400 Bad', self.request(b'GET', page)[0])
        f.peer_inspector = None
        self.assertIn(b'400 Bad', self.request(b'POST', receipt, json.dumps(result('write', f.marker)).encode())[0])
        self.assertFalse(any(event['kind'] == 'durability-result' for event in f.ledger.events))


if __name__ == '__main__': unittest.main()
