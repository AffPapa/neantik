"""Owned TLS origin and an authenticated CONNECT tunnel, research only."""
import base64
import ipaddress
from pathlib import Path
import re
import select
import socket
import ssl
import subprocess
import time

import probe
from turn_tcp_fixture import TURN_BROWSER_STATUSES, TurnTCPFixture, turn_probe_fragment

NAME = 'owned-tls.invalid'


def fetch_destination(header):
    """Retain only a coarse browser-supplied category, never raw headers."""
    values = []
    for line in header.split(b'\r\n')[1:]:
        name, separator, value = line.partition(b':')
        if separator and name.strip().lower() == b'sec-fetch-dest':
            values.append(value.strip().lower())
    if len(values) != 1:
        return 'missing' if not values else 'ambiguous'
    return {b'document': 'document', b'iframe': 'iframe',
            b'empty': 'empty'}.get(values[0], 'other')


def certificates(root, address, name=NAME):
    ipaddress.IPv4Address(address)
    if name != NAME and not (name == TurnTCPFixture.host and address == '127.0.0.1') and not re.fullmatch(
            r'[0-9a-f]{32}\.neantik-dns\.(?:test|invalid)', name):
        raise ValueError('Only owned TLS fixture names are accepted')
    root.mkdir(mode=0o700)
    (root / 'ca.cnf').write_text('[req]\ndistinguished_name=dn\n[dn]\n[ca_ext]\n'
                               'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n'
                               'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always,issuer\n')
    (root / 'leaf.ext').write_text('basicConstraints=critical,CA:FALSE\n'
                                 'keyUsage=critical,digitalSignature,keyEncipherment\n'
                                 'extendedKeyUsage=serverAuth\n'
                                 'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
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
    def __init__(self, host, marker, certificate_root, persistence_nonce=None, *, click_probe=False,
                 attribute_routes=False):
        if persistence_nonce is not None and not re.fullmatch(r'[0-9a-f]{32}', persistence_nonce):
            raise ValueError('Exact random persistence nonce required')
        self.persistence_nonce = persistence_nonce
        self.proxy_peers = {}
        self.attribute_routes = attribute_routes
        self.click_probe = click_probe
        self.turn_probe_token = None
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(str(certificate_root / 'leaf.pem'), str(certificate_root / 'leaf.key'))
        super().__init__(host, marker)
        with self.lock:
            self.counts.update(handshakeComplete=0, handshakeTimeout=0,
                               handshakeTLSFailure=0, handshakeOtherFailure=0,
                               pageResponses=0, stateInitial=0, stateRestored=0)
            if attribute_routes:
                self.counts['unattributedConnections'] = 0
        # The headed WebKit isolation fixture needs request ordering to tell a
        # first-load persistence failure from a repeated navigation or a lost
        # async acknowledgement. Keep only closed request categories and
        # monotonic timestamps; never retain URL, cookie, or nonce values.
        self.persistence_request_trace = []

    def record_persistence_request(self, category, result, destination=None, *, route=None):
        if self.persistence_nonce is None:
            return
        with self.lock:
            event = {
                'atMonotonicNs': time.monotonic_ns(),
                'category': category,
                'result': result,
            }
            if destination is not None:
                event['fetchDestination'] = destination
            if route is not None:
                event['route'] = route
            self.persistence_request_trace.append(event)

    def snapshot(self):
        with self.lock:
            result = dict(self.counts)
            if self.persistence_nonce is not None:
                result['requestTrace'] = [dict(event) for event in self.persistence_request_trace]
            return result

    def arm_turn_probe(self, target, token, *, outage: bool = False):
        if self.persistence_nonce is None:
            raise ValueError('TURN probe requires the owned HTTPS fixture')
        fragment = turn_probe_fragment(target, token, outage=outage)
        with self.lock:
            if self.turn_probe_token is not None:
                raise ValueError('TURN probe already armed')
            self.turn_probe_token = token
            self.marker += fragment

    def disarm_turn_probe(self, base_page):
        with self.lock:
            self.turn_probe_token = None
            self.marker = base_page

    def serve_persistence(self, client, route):
        category = 'unread'
        try:
            client.settimeout(6)
            if self.refusing:
                self.record_persistence_request('unread', 'refused', route=route)
                self.increment('refused'); return
            header = probe.read_header(client)
            request = header.split(b'\r\n', 1)[0]
            if request == b'GET / HTTP/1.1':
                category = 'page'
                body = ('<!doctype html><body>' + self.marker + '</body>').encode()
                kind = 'pageResponses'
                content_type = b'text/html'
            else:
                initial = f'GET /qa-state/{self.persistence_nonce}/initial HTTP/1.1'.encode()
                restored = f'GET /qa-state/{self.persistence_nonce}/restored HTTP/1.1'.encode()
                peer = None
                for top in ('absent', 'created', 'rejected', 'error', 'timeout'):
                    for frame in ('absent', 'created', 'rejected', 'error', 'timeout'):
                        expected = f'GET /qa-peer/{self.persistence_nonce}/{top}/{frame} HTTP/1.1'.encode()
                        if request == expected:
                            peer = f'peer-{top}-{frame}'
                gpu = None
                for result in ('absent', 'adapter', 'unavailable', 'error', 'timeout'):
                    expected = f'GET /qa-gpu/{self.persistence_nonce}/{result} HTTP/1.1'.encode()
                    if request == expected:
                        gpu = f'gpu-{result}'
                turn = None
                if self.turn_probe_token is not None:
                    for result in TURN_BROWSER_STATUSES:
                        expected = f'GET /qa-turn/{self.turn_probe_token}/{result} HTTP/1.1'.encode()
                        if request == expected:
                            turn = f'turn-{result}'
                click = None
                if self.click_probe:
                    for result in ('trusted', 'untrusted'):
                        if request == f'GET /qa-click/{self.persistence_nonce}/{result} HTTP/1.1'.encode():
                            click = f'click-{result}'
                control = peer or gpu or turn or click
                if request not in (initial, restored) and control is None:
                    self.record_persistence_request('unrecognized', 'refused', route=route)
                    self.increment('refused'); return
                category = control or ('initial' if request == initial else 'restored')
                body = b'ack'
                kind = None if control else ('stateInitial' if request == initial else 'stateRestored')
                content_type = b'text/plain'
            client.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: ' + content_type
                           + b'\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: '
                           + str(len(body)).encode() + b'\r\n\r\n' + body)
            self.record_persistence_request(category, 'responded',
                                            fetch_destination(header) if category == 'page' else None, route=route)
            self.increment('responses')
            if kind is not None:
                self.increment(kind)
        except (OSError, EOFError, ValueError, UnicodeError):
            self.record_persistence_request(category, 'failed', route=route)
            self.increment('refused')

    def handle(self, client):
        wrapped = None
        try:
            route = None
            if self.attribute_routes:
                with self.lock:
                    route = self.proxy_peers.get(client.getpeername(), 'unattributed')
                    if route == 'unattributed':
                        self.counts['unattributedConnections'] += 1
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
                self.serve_persistence(wrapped, route)
        except OSError:
            self.increment('refused')
        finally:
            with self.lock:
                self.active.discard(client)
                if wrapped: self.active.discard(wrapped)
            if wrapped: wrapped.close()
            client.close()


class Tunnel(probe.Endpoint):
    def __init__(self, destinations, authorization, port=0, dns_validator=None, *, turn_target=None, route=None):
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
        if route not in (None, 'A', 'B') or (route is not None and any(
                address[0] != '127.0.0.1' for address in owned.values())):
            raise ValueError('Route attribution requires an owned loopback destination')
        self.route = route
        self.origins = destinations.copy()
        # Keep the bound address as immutable fixture metadata. The origin
        # socket is closed during teardown, but final counters are collected
        # afterwards to prove all channels drained.
        self.origin_addresses = {id(origin): (host, number)
                                 for authority, origin in destinations.items()
                                 for host, number in (owned[authority],)}
        self.dns_validator = dns_validator
        if turn_target is not None:
            if not isinstance(turn_target, TurnTCPFixture):
                raise ValueError('A live owned TURN fixture is required')
            destination = turn_target.loopback_destination(turn_target.authority)
            if turn_target.authority in owned or destination in owned.values():
                raise ValueError('TURN and TLS fixture destinations must be distinct')
        self.turn_target = turn_target
        self.target_counts = {}
        self.turn_count = 0
        self.turn_outage_refusals = 0
        self.turn_outage_enabled = False
        super().__init__('127.0.0.1', '', auth=authorization, port=port)

    def authenticated_turn_count(self):
        with self.lock:
            return self.turn_count

    def set_turn_outage(self, enabled):
        with self.lock:
            self.turn_outage_enabled = enabled

    def turn_outage_count(self):
        with self.lock:
            return self.turn_outage_refusals

    def authenticated_for(self, origin):
        if not isinstance(origin, TLSOrigin): raise ValueError('Owned origin required')
        destination = self.origin_addresses.get(id(origin))
        if destination is None: raise ValueError('Origin is outside this owned fixture')
        with self.lock:
            return self.target_counts.get(destination, 0)

    def handle(self, client):
        upstream = None
        tracked_origin = None
        tracked_peer = None
        try:
            client.settimeout(4)
            if self.refusing:
                self.increment('refused'); return
            header, _, extra = probe.read_header(client).partition(b'\r\n\r\n')
            if extra:
                raise ValueError('CONNECT data before response')
            first, *lines = header.split(b'\r\n')
            request = first.decode('ascii').split(' ')
            if len(request) != 3 or request[0] != 'CONNECT' or request[2] != 'HTTP/1.1':
                self.increment('refused'); return
            authority = request[1]
            is_turn = self.turn_target is not None and authority in (
                self.turn_target.authority, self.turn_target.direct_canary_authority)
            destination = (self.turn_target.loopback_destination(authority)
                           if is_turn else self.destinations.get(authority))
            if destination is None:
                self.increment('refused'); return
            fields = {}
            for line in lines:
                name, separator, value = line.partition(b':')
                name = name.lower()
                if not separator or not re.fullmatch(rb"[a-z0-9!#$%&'*+.^_`|~-]+", name) or name in fields:
                    raise ValueError('Invalid CONNECT header')
                fields[name] = value.strip()
            if (fields.get(b'host', authority.encode()) != authority.encode()
                    or b'transfer-encoding' in fields or fields.get(b'content-length', b'0') != b'0'
                    or b'authorization' in fields):
                raise ValueError('Invalid CONNECT framing')
            if fields.get(b'proxy-authorization') != self.auth:
                client.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\n'
                               b'Proxy-Authenticate: Basic realm="Owned TLS QA"\r\n'
                               b'Content-Length: 0\r\nConnection: close\r\n\r\n')
                return
            with self.lock:
                deny_turn = is_turn and (self.turn_outage_enabled or authority == self.turn_target.direct_canary_authority)
                if deny_turn:
                    self.turn_outage_refusals += 1
            if deny_turn:
                client.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            if not is_turn and self.dns_validator is not None and not self.dns_validator(authority, destination):
                self.increment('refused')
                client.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            if self.route is not None and not is_turn:
                origin = self.origins[authority]
                upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                upstream.settimeout(4)
                upstream.bind(('127.0.0.1', 0))
                tracked_peer = upstream.getsockname()
                with origin.lock:
                    origin.proxy_peers[tracked_peer] = self.route
                tracked_origin = origin
                upstream.connect(destination)
            else:
                upstream = socket.create_connection(destination, timeout=4)
            with self.lock:
                if self.stopping.is_set(): return
                self.active.add(upstream)
            self.increment('authenticated')
            with self.lock:
                if is_turn:
                    self.turn_count += 1
                else:
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
            if tracked_origin is not None:
                with tracked_origin.lock:
                    tracked_origin.proxy_peers.pop(tracked_peer, None)
            with self.lock:
                self.active.discard(client)
                if upstream: self.active.discard(upstream)
            if upstream: upstream.close()
            client.close()


def authorization(username, password):
    return b'Basic ' + base64.b64encode(f'{username}:{password}'.encode())
