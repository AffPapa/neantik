"""Owned TLS origin and an authenticated CONNECT tunnel, research only."""
import base64
import ipaddress
from pathlib import Path
import re
import select
import socket
import ssl
import subprocess

import probe

NAME = 'owned-tls.invalid'


def certificates(root, address, name=NAME):
    ipaddress.IPv4Address(address)
    if name != NAME and not re.fullmatch(r'[0-9a-f]{32}\.neantik-dns\.(?:test|invalid)', name):
        raise ValueError('Only the owned random DNS fixture name is accepted')
    root.mkdir(mode=0o700)
    (root / 'ca.cnf').write_text('[req]\ndistinguished_name=dn\n[dn]\n[ca_ext]\n'
                               'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n')
    (root / 'leaf.ext').write_text('basicConstraints=critical,CA:FALSE\n'
                                 'keyUsage=critical,digitalSignature,keyEncipherment\n'
                                 'extendedKeyUsage=serverAuth\n'
                                 f'subjectAltName=DNS:{name},IP:{address}\n')
    outputs = []
    for stem in ('ca', 'wrong-ca'):
        commands = [['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2',
                     '-subj', '/CN=NeAntik isolated TLS QA ' + stem, '-config', str(root / 'ca.cnf'),
                     '-extensions', 'ca_ext', '-keyout', str(root / (stem + '.key')), '-out', str(root / (stem + '.pem'))],
                    ['x509', '-in', str(root / (stem + '.pem')), '-outform', 'DER', '-out', str(root / (stem + '.der'))]]
        for command in commands:
            output = subprocess.run(['/usr/bin/openssl', *command], capture_output=True)
            outputs.append(output.stderr)
            if output.returncode: raise RuntimeError('Own QA root generation failed')
        (root / (stem + '.key')).chmod(0o600)
    for command in [
        ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=' + name,
         '-keyout', str(root / 'leaf.key'), '-out', str(root / 'leaf.csr')],
        ['x509', '-req', '-in', str(root / 'leaf.csr'), '-CA', str(root / 'ca.pem'),
         '-CAkey', str(root / 'ca.key'), '-set_serial', '1', '-days', '2', '-sha256',
         '-extfile', str(root / 'leaf.ext'), '-out', str(root / 'leaf.pem')]]:
        output = subprocess.run(['/usr/bin/openssl', *command], capture_output=True)
        outputs.append(output.stderr)
        if output.returncode: raise RuntimeError('Own QA leaf generation failed')
    (root / 'leaf.key').chmod(0o600)
    (root / 'generation.stderr').write_bytes(b'\n'.join(outputs))
    return root


class TLSOrigin(probe.Endpoint):
    def __init__(self, host, marker, certificate_root, persistence_nonce=None):
        if persistence_nonce is not None and not re.fullmatch(r'[0-9a-f]{32}', persistence_nonce):
            raise ValueError('Exact random persistence nonce required')
        self.persistence_nonce = persistence_nonce
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(str(certificate_root / 'leaf.pem'), str(certificate_root / 'leaf.key'))
        super().__init__(host, marker)
        with self.lock:
            self.counts.update(handshakeComplete=0, handshakeTimeout=0,
                               handshakeTLSFailure=0, handshakeOtherFailure=0,
                               pageResponses=0, stateInitial=0, stateRestored=0)

    def serve_persistence(self, client):
        try:
            client.settimeout(6)
            if self.refusing:
                self.increment('refused'); return
            request = probe.read_header(client).split(b'\r\n', 1)[0]
            if request == b'GET / HTTP/1.1':
                body = ('<!doctype html><body>' + self.marker + '</body>').encode()
                kind = 'pageResponses'
                content_type = b'text/html'
            else:
                initial = f'GET /qa-state/{self.persistence_nonce}/initial HTTP/1.1'.encode()
                restored = f'GET /qa-state/{self.persistence_nonce}/restored HTTP/1.1'.encode()
                if request not in (initial, restored):
                    self.increment('refused'); return
                body = b'ack'
                kind = 'stateInitial' if request == initial else 'stateRestored'
                content_type = b'text/plain'
            client.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: ' + content_type
                           + b'\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: '
                           + str(len(body)).encode() + b'\r\n\r\n' + body)
            self.increment('responses')
            self.increment(kind)
        except (OSError, EOFError, ValueError, UnicodeError):
            self.increment('refused')

    def handle(self, client):
        wrapped = None
        try:
            # A headed WebKit trust challenge can pause the client while the
            # delegate evaluates the exact QA anchor. Four seconds classified
            # that pause as a TLS refusal and hid the actual boundary.
            client.settimeout(12)
            wrapped = self.context.wrap_socket(client, server_side=True, do_handshake_on_connect=False)
            with self.lock:
                self.active.discard(client)
                if self.stopping.is_set(): return
                self.active.add(wrapped)
            try:
                wrapped.do_handshake()
            except socket.timeout:
                self.increment('handshakeTimeout')
                raise
            except ssl.SSLError:
                self.increment('handshakeTLSFailure')
                raise
            except OSError:
                self.increment('handshakeOtherFailure')
                raise
            self.increment('handshakeComplete')
            if self.persistence_nonce is None:
                super().handle(wrapped)
            else:
                self.serve_persistence(wrapped)
        except OSError:
            self.increment('refused')
        finally:
            with self.lock:
                self.active.discard(client)
                if wrapped: self.active.discard(wrapped)
            if wrapped: wrapped.close()
            client.close()


class Tunnel(probe.Endpoint):
    def __init__(self, destinations, authorization, port=0, dns_validator=None):
        if dns_validator is not None and not callable(dns_validator):
            raise ValueError('Owned DNS validator must be callable')
        owned = {}
        for authority, origin in destinations.items():
            if not isinstance(origin, TLSOrigin) or not origin.thread.is_alive():
                raise ValueError('A live owned TLSOrigin capability is required')
            host, number = origin.socket.getsockname()
            if not ipaddress.ip_address(host).is_private:
                raise ValueError('Own fixture must be local')
            owned[authority] = (host, number)
        self.destinations = owned
        self.dns_validator = dns_validator
        self.target_counts = {}
        super().__init__('127.0.0.1', '', auth=authorization, port=port)

    def authenticated_for(self, origin):
        if not isinstance(origin, TLSOrigin): raise ValueError('Owned origin required')
        destination = origin.socket.getsockname()
        with self.lock:
            return self.target_counts.get(destination, 0)

    def handle(self, client):
        upstream = None
        try:
            client.settimeout(4)
            if self.refusing:
                self.increment('refused'); return
            header = probe.read_header(client)
            request = header.split(b'\r\n', 1)[0].decode('ascii').split(' ')
            if len(request) != 3 or request[0] != 'CONNECT' or request[2] != 'HTTP/1.1':
                self.increment('refused'); return
            destination = self.destinations.get(request[1])
            if destination is None:
                self.increment('refused'); return
            fields = {line.split(b':', 1)[0].lower(): line.split(b':', 1)[1].strip()
                      for line in header.split(b'\r\n')[1:] if b':' in line}
            if fields.get(b'proxy-authorization') != self.auth:
                client.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\n'
                               b'Proxy-Authenticate: Basic realm="Owned TLS QA"\r\n'
                               b'Content-Length: 0\r\nConnection: close\r\n\r\n')
                return
            if self.dns_validator is not None and not self.dns_validator(request[1], destination):
                self.increment('refused')
                client.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            upstream = socket.create_connection(destination, timeout=4)
            with self.lock:
                if self.stopping.is_set(): return
                self.active.add(upstream)
            self.increment('authenticated')
            with self.lock:
                self.target_counts[destination] = self.target_counts.get(destination, 0) + 1
            client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            count = 0
            while not self.stopping.is_set():
                readable, _, _ = select.select([client, upstream], [], [], .1)
                for source in readable:
                    data = source.recv(16384)
                    if not data: return
                    count += len(data)
                    if count > 2 * 1024 * 1024:
                        self.increment('refused'); return
                    (upstream if source is client else client).sendall(data)
        except (OSError, ValueError, EOFError, UnicodeError):
            self.increment('refused')
        finally:
            with self.lock:
                self.active.discard(client)
                if upstream: self.active.discard(upstream)
            if upstream: upstream.close()
            client.close()


def authorization(username, password):
    return b'Basic ' + base64.b64encode(f'{username}:{password}'.encode())
