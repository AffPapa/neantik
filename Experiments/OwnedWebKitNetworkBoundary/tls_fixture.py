"""Owned TLS origin and an authenticated CONNECT tunnel, research only."""
import base64
import ipaddress
from pathlib import Path
import select
import socket
import ssl
import subprocess

import probe

NAME = 'owned-tls.invalid'


def certificates(root, address):
    ipaddress.IPv4Address(address)
    root.mkdir(mode=0o700)
    (root / 'ca.cnf').write_text('[req]\ndistinguished_name=dn\n[dn]\n[ca_ext]\n'
                               'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n')
    (root / 'leaf.ext').write_text('basicConstraints=critical,CA:FALSE\n'
                                 'keyUsage=critical,digitalSignature,keyEncipherment\n'
                                 'extendedKeyUsage=serverAuth\n'
                                 f'subjectAltName=DNS:{NAME},IP:{address}\n')
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
        ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=' + NAME,
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
    def __init__(self, host, marker, certificate_root):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(str(certificate_root / 'leaf.pem'), str(certificate_root / 'leaf.key'))
        super().__init__(host, marker)

    def handle(self, client):
        wrapped = None
        try:
            client.settimeout(4)
            wrapped = self.context.wrap_socket(client, server_side=True, do_handshake_on_connect=False)
            with self.lock:
                self.active.discard(client)
                if self.stopping.is_set(): return
                self.active.add(wrapped)
            wrapped.do_handshake()
            super().handle(wrapped)
        except OSError:
            self.increment('refused')
        finally:
            with self.lock:
                self.active.discard(client)
                if wrapped: self.active.discard(wrapped)
            if wrapped: wrapped.close()
            client.close()


class Tunnel(probe.Endpoint):
    def __init__(self, destinations, authorization, port=0):
        owned = {}
        for authority, origin in destinations.items():
            if not isinstance(origin, TLSOrigin) or not origin.thread.is_alive():
                raise ValueError('A live owned TLSOrigin capability is required')
            host, number = origin.socket.getsockname()
            if not ipaddress.ip_address(host).is_private:
                raise ValueError('Own fixture must be local')
            owned[authority] = (host, number)
        self.destinations = owned
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
