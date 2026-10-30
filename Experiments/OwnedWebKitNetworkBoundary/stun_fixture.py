"""Single-threaded owned UDP4 STUN responder; never exports raw ICE or IPs."""
import ipaddress
import os
import socket
import struct
import threading

COOKIE = 0x2112A442


def request(transaction):
    if not isinstance(transaction, bytes) or len(transaction) != 12: raise ValueError('Transaction bound')
    return struct.pack('!HHI', 1, 0, COOKIE) + transaction


def response(packet, peer):
    if not isinstance(packet, bytes) or not 20 <= len(packet) <= 4096: raise ValueError('Packet bound')
    kind, size, cookie = struct.unpack('!HHI', packet[:8])
    if kind != 1 or cookie != COOKIE or size % 4 or size + 20 != len(packet): raise ValueError('STUN header')
    ip = int(ipaddress.IPv4Address(peer[0])); port = peer[1]
    if type(port) is not int or not 1 <= port <= 65535: raise ValueError('Peer port')
    return (struct.pack('!HHI', 0x101, 12, COOKIE) + packet[8:20] +
            struct.pack('!HHBBHI', 0x20, 8, 0, 1, port ^ 0x2112, ip ^ COOKIE))


class OwnedSTUN:
    def __init__(self, address):
        if not ipaddress.ip_address(address).is_private: raise ValueError('Own local fixture required')
        self.address = address; self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((address, 0)); self.socket.settimeout(.1)
        self.port = self.socket.getsockname()[1]
        self.canary = os.urandom(12); self.browser_requests = 0; self.invalid = 0
        self.stopping = threading.Event(); self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.serve, daemon=True); self.thread.start()

    def serve(self):
        while not self.stopping.is_set():
            try: packet, peer = self.socket.recvfrom(4097)
            except socket.timeout: continue
            except OSError: break
            try:
                if peer[0] != self.address: raise ValueError('Foreign peer')
                answer = response(packet, peer)
                if packet[8:20] != self.canary:
                    with self.lock: self.browser_requests += 1
                self.socket.sendto(answer, peer)
            except (ValueError, OSError):
                with self.lock: self.invalid += 1

    def verify_canary(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.bind((self.address, 0)); client.settimeout(2)
            client.sendto(request(self.canary), (self.address, self.port))
            answer, sender = client.recvfrom(4096)
            expected = response(request(self.canary), client.getsockname())
            if sender != (self.address, self.port) or answer != expected:
                raise ValueError('STUN canary mismatch')
        with self.lock:
            if self.browser_requests or self.invalid: raise ValueError('STUN baseline not empty')
        return True

    def snapshot(self):
        with self.lock: return {'browserRequests': self.browser_requests, 'invalidRequests': self.invalid}

    def stop(self):
        self.stopping.set()
        try: self.socket.sendto(request(self.canary), (self.address, self.port))
        except OSError: pass
        self.thread.join(2); self.socket.close()
        return not self.thread.is_alive()
