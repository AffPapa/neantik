#!/usr/bin/env python3
"""Own DNS-on-wire fixture, not a browser/privacy qualification by itself.

Extends the existing HTTP-auth upstream without changing its ordinary route.
Only randomly named fixture destinations resolve to the own loopback origin.
No system resolver settings, raw ambient packets or user credentials are read.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import socketserver
import stat
import struct
import ssl
import subprocess
import sys
import threading
import uuid
from urllib.parse import parse_qs, urlsplit, urlunsplit

BASE_PATH = Path(__file__).with_name('manager-route-fixture.py')
SPEC = importlib.util.spec_from_file_location('owned_dns_route_base', BASE_PATH)
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)
MAX_PACKET = 4096


class DNSMessageError(ValueError):
    pass


def question(packet, *, response=False):
    """Parse one uncompressed question plus optional bounded EDNS OPT.

    Our requests never compress names. Pointer-bearing/multi-question requests
    are rejected rather than inferred; replies reuse the exact question bytes.
    """
    if not isinstance(packet, bytes) or not 17 <= len(packet) <= MAX_PACKET:
        raise DNSMessageError('packet bound')
    identifier, flags, count, answers, authority, additional = struct.unpack('!6H', packet[:12])
    if bool(flags & 0x8000) != response or flags & 0x7A00 or count != 1 or authority:
        raise DNSMessageError('header')
    if (not response and answers) or answers > 1 or additional > 1:
        raise DNSMessageError('record counts')
    if flags & 0x0040 or (not response and flags & 0x048F):
        raise DNSMessageError('reserved or response-only flags')
    offset, labels, total = 12, [], 1
    while True:
        if offset >= len(packet): raise DNSMessageError('name truncated')
        size = packet[offset]; offset += 1
        if not size: break
        if size > 63 or offset + size > len(packet): raise DNSMessageError('name label')
        label = packet[offset:offset + size]
        if not all(byte == 45 or 48 <= byte <= 57 or 65 <= byte <= 90 or 97 <= byte <= 122 for byte in label):
            raise DNSMessageError('non fixture name')
        if label[0] == 45 or label[-1] == 45: raise DNSMessageError('label boundary')
        total += size + 1
        if total > 255: raise DNSMessageError('name bound')
        labels.append(label.decode('ascii').lower()); offset += size
    if not labels or offset + 4 > len(packet): raise DNSMessageError('question')
    kind, klass = struct.unpack('!HH', packet[offset:offset + 4]); offset += 4
    if klass != 1: raise DNSMessageError('question class')
    end = offset
    if answers:
        # Only our fixed IPv4 answer is accepted by the upstream resolver.
        if packet[offset:offset + 12] != b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x00\x00\x04':
            raise DNSMessageError('answer encoding')
        offset += 16
        if offset > len(packet): raise DNSMessageError('answer truncated')
    if additional:
        if response or offset + 11 > len(packet) or packet[offset] != 0:
            raise DNSMessageError('OPT record')
        opt_type, _, _, length = struct.unpack('!HHIH', packet[offset + 1:offset + 11])
        if opt_type != 41: raise DNSMessageError('additional type')
        offset += 11 + length
    if offset != len(packet): raise DNSMessageError('trailing or truncated records')
    return dict(identifier=identifier, flags=flags, name='.'.join(labels), kind=kind,
                question=packet[12:end], answers=answers, rcode=flags & 15)


def query(name, identifier):
    labels = name.encode('ascii').split(b'.')
    wire = b''.join(bytes([len(label)]) + label for label in labels) + b'\0\0\1\0\1'
    packet = struct.pack('!6H', identifier, 0x0100, 1, 0, 0, 0) + wire
    question(packet)
    return packet


def reply(packet, *, known, refused=False):
    q = question(packet)
    code = 2 if refused else 0 if known else 3
    has_address = code == 0 and q['kind'] == 1
    header = struct.pack('!6H', q['identifier'], 0x8400 | (q['flags'] & 0x0100) | code,
                         1, int(has_address), 0, 0)
    answer = b'\xc0\x0c\0\1\0\1\0\0\0\0\0\4\x7f\0\0\1' if has_address else b''
    return header + q['question'] + answer


class DNSFixture(BASE.Fixture):
    # This fixture has no reason to dial even the base fixture's GeoIP hosts.
    public_tls_hosts = frozenset()

    def __init__(self, root):
        root = Path(root)
        mode = root.lstat()
        if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o077:
            raise ValueError('own private fixture root required')
        self.names, self.dns = {}, None
        super().__init__(root)
        try:
            for phase in ('dns-refused', 'doh-refused', 'bypass-control'):
                self.nonces[phase] = uuid.uuid4().hex
            self.names = {phase: uuid.uuid4().hex + '.neantik-dns.test' for phase in self.nonces}
            self.reverse_names = {name: phase for phase, name in self.names.items()}
            owner = self
            class Handler(socketserver.BaseRequestHandler):
                def handle(self):
                    packet, server = self.request
                    try:
                        q = question(packet)
                        phase = owner.reverse_names.get(q['name'])
                        refused = phase is not None and (owner.root / 'fail-dns').exists()
                        result = reply(packet, known=phase is not None, refused=refused)
                        server.sendto(result, self.client_address)
                        owner.ledger.record('dns-wire', phase=phase, transport='udp',
                            queryType=q['kind'], rcode=2 if refused else 0 if phase else 3,
                            responseSent=True)
                    except (DNSMessageError, OSError):
                        owner.ledger.record('dns-invalid-packet')
            # One bounded parser per datagram, not unbounded per-query threads.
            self.dns = socketserver.UDPServer(('127.0.0.1', 0), Handler)
            self.dns.max_packet_size = MAX_PACKET + 1
            self.dns_thread = threading.Thread(target=self.dns.serve_forever,
                                               kwargs={'poll_interval': .05}, daemon=True)
            self.dns_thread.start()
        except BaseException:
            super().close()
            if self.dns is not None: self.dns.server_close()
            raise

    def url(self, phase):
        original = urlsplit(super().url(phase))
        return urlunsplit(original._replace(netloc=self.names[phase] + ':' + str(self.origin.server_address[1])))

    def owned_local_destination(self, host, port):
        return super().owned_local_destination(host, port) or (
            host in self.names.values() and port == self.origin.server_address[1])

    def open_upstream(self, host, port):
        if host not in self.names.values(): return super().open_upstream(host, port)
        if port != self.origin.server_address[1]: raise OSError('owned origin port mismatch')
        identifier = int.from_bytes(os.urandom(2), 'big')
        packet = query(host, identifier)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel:
            channel.settimeout(2)
            channel.sendto(packet, self.dns.server_address)
            answer, sender = channel.recvfrom(MAX_PACKET + 1)
        q = question(answer, response=True)
        if (sender != self.dns.server_address or q['identifier'] != identifier or q['name'] != host
                or q['kind'] != 1 or q['rcode'] != 0 or q['answers'] != 1
                or answer[-4:] != b'\x7f\0\0\1'):
            self.resolution_result(host, accepted=False, rcode=q['rcode'])
            raise OSError('owned DNS resolution refused')
        self.resolution_result(host, accepted=True, rcode=0)
        return super().open_upstream('127.0.0.1', port)

    def resolution_result(self, host, *, accepted, rcode):
        # Manager integration records the validated answer before dialing.
        # Raw-runtime fixture behavior and its ledger stay unchanged.
        pass

    def description(self):
        return dict(schemaVersion=1, urls={p: self.url(p) for p in self.nonces},
                    dnsPort=self.dns.server_address[1], proxyPort=self.proxy.server_address[1],
                    originPort=self.origin.server_address[1],
                    scope='fixture only; no Chromium or global DNS qualification')

    def close(self):
        if self.dns is not None:
            self.dns.shutdown(); self.dns.server_close(); self.dns_thread.join(3)
            self.dns = None
        return super().close()


def own_certificate(root):
    """Create a one-day fixture certificate, never installed in an OS trust store."""
    root = Path(root)
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('own private certificate root required')
    configuration = root / 'owned-tls.cnf'
    with configuration.open('x') as stream:
        stream.write('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n'
            '[dn]\nCN=Owned DNS fixture\n[v3]\nsubjectAltName=IP:127.0.0.1\n'
            'basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n'
            'extendedKeyUsage=serverAuth\n')
    configuration.chmod(0o600)
    certificate, key = root/'owned-tls.pem', root/'owned-tls-key.pem'
    if any(p.exists() or p.is_symlink() for p in (certificate, key)):
        raise ValueError('fixture certificate cannot replace existing files')
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(root)}
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-days', '1', '-config', str(configuration), '-keyout', str(key), '-out', str(certificate)],
        env=env, capture_output=True, check=True, timeout=20)
    certificate.chmod(0o600); key.chmod(0o600)
    public = subprocess.run(['/usr/bin/openssl', 'x509', '-in', str(certificate), '-pubkey', '-noout'],
        env=env, capture_output=True, check=True, timeout=5).stdout
    der = subprocess.run(['/usr/bin/openssl', 'pkey', '-pubin', '-outform', 'DER'], input=public,
        env=env, capture_output=True, check=True, timeout=5).stdout
    return certificate, key, base64.b64encode(hashlib.sha256(der).digest()).decode('ascii')


class DNSOverHTTPSFixture(DNSFixture):
    """RFC8484 fixture on HTTPS; its self-signed cert is a disclosed test override.

    A separate transport counter makes browser DoH distinct from upstream UDP.
    This deliberately implements only one-question DNS and HTTP/1.1, not a
    general DNS server. No public DNS resolver or external destination is used.
    """
    def __init__(self, root, certificate, key, spki):
        self.doh = None
        super().__init__(root)
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.set_alpn_protocols(['http/1.1'])
            context.load_cert_chain(certificate, key)
            self.spki = spki
            owner = self
            class Handler(socketserver.BaseRequestHandler):
                def handle(self):
                    tls = None
                    try:
                        self.request.settimeout(3)
                        tls = context.wrap_socket(self.request, server_side=True, do_handshake_on_connect=False)
                        owner.track(tls)
                        tls.do_handshake()
                        owner.doh_request(tls)
                    except (OSError, ValueError): owner.ledger.record('doh-transport-failure')
                    finally:
                        if tls is not None: owner.untrack(tls); tls.close()
            class Server(socketserver.ThreadingTCPServer):
                daemon_threads = True
                block_on_close = False
                slots = threading.BoundedSemaphore(8)
                def process_request(self, request, client):
                    if not self.slots.acquire(blocking=False):
                        owner.ledger.record('doh-capacity-refusal'); self.shutdown_request(request); return
                    try: super().process_request(request, client)
                    except BaseException: self.slots.release(); raise
                def process_request_thread(self, request, client):
                    try: super().process_request_thread(request, client)
                    finally: self.slots.release()
                def handle_error(self, *_): owner.ledger.record('doh-handler-failure')
            self.doh = Server(('127.0.0.1', 0), Handler)
            self.doh_thread = threading.Thread(target=self.doh.serve_forever,
                                               kwargs={'poll_interval': .05}, daemon=True)
            self.doh_thread.start()
        except BaseException:
            super().close()
            if self.doh is not None: self.doh.server_close()
            raise

    def doh_request(self, channel):
        request = BASE.header(channel)
        lines = request[:-4].split(b'\r\n')
        method, target, version = lines[0].decode('ascii').split(' ')
        fields = {}
        for line in lines[1:]:
            name, value = line.decode('ascii').split(':', 1)
            name = name.lower()
            if name in fields: raise ValueError('duplicate HTTP field')
            fields[name] = value.strip()
        parsed = urlsplit(target)
        if version != 'HTTP/1.1' or parsed.scheme or parsed.netloc or parsed.path != '/dns-query':
            BASE.answer(channel, b'404 Not Found', b''); return
        if 'transfer-encoding' in fields: raise ValueError('chunked DoH unsupported')
        size = int(fields.get('content-length', '0'))
        if not 0 <= size <= MAX_PACKET: raise ValueError('DoH body bound')
        if method == 'POST':
            if parsed.query or fields.get('content-type') != 'application/dns-message':
                BASE.answer(channel, b'415 Unsupported Media Type', b''); return
            data = bytearray()
            while len(data) < size:
                chunk = channel.recv(size-len(data))
                if not chunk: raise ValueError('DoH body truncated')
                data.extend(chunk)
            packet = bytes(data)
        elif method == 'GET':
            params = parse_qs(parsed.query, keep_blank_values=True)
            if size or set(params) != {'dns'} or len(params['dns']) != 1:
                raise ValueError('DoH query')
            value = params['dns'][0]
            if len(value) > 4*((MAX_PACKET+2)//3): raise ValueError('DoH query bound')
            packet = base64.b64decode(value+'='*((-len(value))%4), altchars=b'-_', validate=True)
        else:
            BASE.answer(channel, b'405 Method Not Allowed', b''); return
        try: q = question(packet)
        except DNSMessageError:
            BASE.answer(channel, b'400 Bad Request', b''); return
        phase = self.reverse_names.get(q['name'])
        refused = phase is not None and (self.root/'fail-doh').exists()
        body = reply(packet, known=phase is not None, refused=refused)
        channel.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n'
            b'Cache-Control: no-store\r\nConnection: close\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
        self.ledger.record('dns-wire', phase=phase, transport='https', queryType=q['kind'],
                           rcode=2 if refused else 0 if phase else 3, responseSent=True)

    def description(self):
        result = super().description()
        result.update(dohURL='https://127.0.0.1:'+str(self.doh.server_address[1])+'/dns-query',
                      testCertificateSPKI=self.spki,
                      tlsBoundary='own self-signed certificate; test-only scoped SPKI override, not OS-default trust')
        return result

    def close(self):
        if self.doh is not None:
            self.doh.shutdown(); self.doh.server_close(); self.doh_thread.join(3)
            self.doh = None
        return super().close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True,
                        help='An existing empty owned0700 temporary directory')
    parser.add_argument('--doh', action='store_true', help='Add owned HTTPS DNS endpoint with a test-only certificate')
    args = parser.parse_args()
    if not args.root.is_absolute() or args.root.is_symlink() or any(args.root.iterdir()):
        parser.error('root must be absolute, non-symlink and empty')
    if args.doh:
        certificate, key, spki = own_certificate(args.root)
        fixture = DNSOverHTTPSFixture(args.root, certificate, key, spki)
    else: fixture = DNSFixture(args.root)
    try:
        BASE.private_json(args.root / 'fixture-private.json', fixture.description())
        print(json.dumps({'ready': True, 'browserStarted': False}), flush=True)
        # Operator-owned stdin, never a page request, controls fault phases.
        while True:
            line = sys.stdin.readline(1025)
            if not line: break
            if len(line) > 1024: raise ValueError('control bound')
            command = json.loads(line)
            if command == {'action': 'stop'}: break
            raise ValueError('unsupported control')
    finally:
        if not fixture.close(): raise RuntimeError('owned channels did not settle')


if __name__ == '__main__':
    main()
