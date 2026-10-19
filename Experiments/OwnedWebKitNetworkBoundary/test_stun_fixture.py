"""STUN wire controls; no browser or raw candidate output."""
import os
import socket
import struct
import time
import unittest

from stun_fixture import COOKIE, OwnedSTUN, request, response


class STUNTests(unittest.TestCase):
    def test_response_echoes_transaction_and_correct_xor_mapping(self):
        transaction = os.urandom(12)
        reply = response(request(transaction), ('127.0.0.1', 54321))
        self.assertEqual(len(reply), 32)
        self.assertEqual(struct.unpack('!HHI', reply[:8]), (0x101, 12, COOKIE))
        self.assertEqual(reply[8:20], transaction)
        self.assertEqual(struct.unpack('!H', reply[26:28])[0] ^ 0x2112, 54321)
        self.assertEqual(struct.unpack('!I', reply[28:])[0] ^ COOKIE, 0x7F000001)

    def test_malformed_requests_are_rejected(self):
        valid = request(os.urandom(12))
        for broken in [valid[:19], valid + b'x', valid[:4] + b'bad!' + valid[8:],
                       b'\x01\x01' + valid[2:], valid[:2] + b'\0\1' + valid[4:]]:
            with self.subTest(length=len(broken)), self.assertRaises(ValueError):
                response(broken, ('127.0.0.1', 12345))

    def test_canary_does_not_count_as_browser_and_threads_stop(self):
        server = OwnedSTUN('127.0.0.1')
        try:
            self.assertTrue(server.verify_canary())
            self.assertEqual(server.snapshot(), {'browserRequests': 0, 'invalidRequests': 0})
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.bind(('127.0.0.1', 0)); client.settimeout(2)
                packet = request(os.urandom(12)); client.sendto(packet, ('127.0.0.1', server.port))
                reply, _ = client.recvfrom(4096)
                self.assertEqual(reply, response(packet, client.getsockname()))
            self.assertEqual(server.snapshot()['browserRequests'], 1)
        finally:
            self.assertTrue(server.stop())


if __name__ == '__main__': unittest.main()
