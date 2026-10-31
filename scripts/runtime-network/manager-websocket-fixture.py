"""Fixed owned WS operations through the actual manager/relay; no TLS bypass.

The fault cuts WS tunnels and refuses new WS CONNECTs while HTTP control pages
remain reachable. This is not physical listener loss or WSS qualification.
"""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import select
import socket
import socketserver
import threading
import uuid
from urllib.parse import parse_qs, urlencode, urlsplit

SPEC = importlib.util.spec_from_file_location('manager_ws_base', Path(__file__).with_name('manager-route-fixture.py'))
BASE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(BASE)
MODES = ('proxy-success', 'direct-control')
PHASES = ('initial', 'blocked', 'recovered')


def require(value):
    if not value: raise ValueError('owned-ws-input')


def frame(payload, opcode=1):
    require(isinstance(payload, bytes) and len(payload) < 126 and opcode in (1, 8, 10))
    return bytes((0x80 | opcode, len(payload))) + payload


def read_exact(channel, count):
    value = bytearray()
    while len(value) < count:
        chunk = channel.recv(count - len(value))
        if not chunk: raise ValueError('owned-ws-incomplete')
        value.extend(chunk)
    return bytes(value)


def client_frame(channel):
    flags, length = read_exact(channel, 2)
    require(flags & 0xf0 == 0x80 and flags & 15 in (1, 8, 9) and length & 0x80 and length & 127 < 126)
    mask = read_exact(channel, 4); body = read_exact(channel, length & 127)
    return flags & 15, bytes(value ^ mask[i % 4] for i, value in enumerate(body))


def validate_result(value, mode):
    require(isinstance(value, dict) and set(value) == {'mode', 'rows', 'held', 'errors', 'remaining'} and value['mode'] == mode)
    require(type(value['remaining']) is int and 0 <= value['remaining'] <= 8 and isinstance(value['errors'], list)
            and len(value['errors']) <= 4 and all(isinstance(x, str) and len(x) <= 64 for x in value['errors']))
    require(isinstance(value['rows'], list) and len(value['rows']) <= 3)
    for row in value['rows']:
        require(isinstance(row, dict) and set(row) == {'phase', 'opened', 'echoed', 'errored', 'closeCode'}
                and row['phase'] in PHASES and all(type(row[key]) is bool for key in ('opened', 'echoed', 'errored'))
                and (row['closeCode'] is None or type(row['closeCode']) is int and 0 <= row['closeCode'] <= 65535))
    held = value['held']
    require(held is None or isinstance(held, dict) and
            (set(held) == {'aborted', 'closeCode'} and type(held['aborted']) is bool and
             (held['closeCode'] is None or type(held['closeCode']) is int and 0 <= held['closeCode'] <= 65535)
             if mode == 'proxy-success' else set(held) == {'stillOpen'} and type(held['stillOpen']) is bool))
    return value


class ManagerWebSocketFixture(BASE.Fixture):
    def __init__(self, root):
        self.control_lock = threading.RLock(); self.peer_inspector = None
        self.peers = {}; self.ws_channels = set(); self.active_mode = None; self.phase_name = None; self.completed = set()
        super().__init__(root)
        self.nonces = {mode: uuid.uuid4().hex for mode in MODES}
        owner = self
        class Handler(socketserver.BaseRequestHandler):
            def handle(self): owner.websocket_request(self.request)
        self.websocket = type(self.origin)(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=self.websocket.serve_forever, daemon=True)
        self.threads.append(thread); thread.start()

    def navigation_phases(self): return MODES

    def parse(self, target, path, extra=()):
        parsed = urlsplit(target); query = parse_qs(parsed.query, keep_blank_values=True)
        require(len(target) <= 16384 and parsed.path == path and set(query) == {'mode', 'nonce', *extra}
                and all(len(values) == 1 for values in query.values()))
        mode = query['mode'][0]; require(mode in MODES and query['nonce'][0] == self.nonces[mode])
        return mode, {key: values[0] for key, values in query.items()}

    def url(self, phase):
        return self.http_url('/owned-route', phase)

    def http_url(self, path, mode, **extra):
        return 'http://127.0.0.1:' + str(self.origin.server_address[1]) + path + '?' + urlencode(dict(mode=mode, nonce=self.nonces[mode], **extra))

    def description(self): return dict(mode='manager-websocket', protocol='ws', fault='WS CONNECT refused and live WS tunnels cut;HTTP control retained')

    def request_peer(self, channel):
        require(self.peer_inspector is not None)
        with self.control_lock: peer = self.peers.get(channel.getpeername()[1])
        if peer is not None: return dict(route='proxy', **peer)
        return dict(route='direct', custody=self.peer_inspector(channel, True))

    def control(self, mode, phase):
        require(mode in MODES and phase in PHASES)
        with self.control_lock:
            if phase == 'initial':
                require(mode not in self.completed and self.active_mode is None and
                        (mode == 'proxy-success' or 'proxy-success' in self.completed))
                self.active_mode = mode; self.phase_name = phase
            else:
                require(self.active_mode == mode and ((self.phase_name, phase) in (('initial', 'blocked'), ('blocked', 'recovered'))))
                self.phase_name = phase
            channels = list(self.ws_channels) if phase == 'blocked' else []
            self.ledger.record('ws-control', mode=mode, phase=phase, channelsCut=len(channels))
        for channel in channels:
            try: channel.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        return dict(phase=phase)

    def origin_request(self, channel):
        self.track(channel); channel.settimeout(10)
        try:
            request = BASE.header(channel); pieces = request.split(b'\r\n', 1)[0].split(); require(len(pieces) == 3 and pieces[0] == b'GET')
            target = pieces[1].decode('ascii'); path = urlsplit(target).path
            if path == '/favicon.ico': BASE.answer(channel, b'404 Not Found', b''); return
            extra = ('phase',) if path == '/control' else ('result',) if path == '/receipt' else ()
            require(path in ('/owned-route', '/control', '/receipt')); mode, query = self.parse(target, path, extra)
            peer = self.request_peer(channel); require(peer['route'] == ('proxy' if mode == 'proxy-success' else 'direct'))
            if path == '/control':
                phase = query['phase']; require(phase in PHASES); body = json.dumps(self.control(mode, phase)).encode()
            elif path == '/receipt':
                value = validate_result(json.loads(query['result']), mode)
                with self.control_lock:
                    require(self.active_mode == mode and mode not in self.completed)
                    self.completed.add(mode); self.active_mode = None
                self.ledger.record('ws-result', mode=mode, result=value, peer=peer); body = b'owned receipt accepted'
            else:
                config = dict(mode=mode, nonce=self.nonces[mode], control=self.http_url('/control', mode), receipt=self.http_url('/receipt', mode),
                              websocket='ws://127.0.0.1:' + str(self.websocket.server_address[1]) + '/echo?' + urlencode(dict(mode=mode, nonce=self.nonces[mode])))
                probe = Path(__file__).with_name('manager-websocket-probe.js').read_text()
                body = ('<!doctype html><meta charset="utf-8"><body data-fixture="' + self.nonces[mode] + '"><h1>Owned manager WS</h1><p id="result">Running</p><script>globalThis.OWN_MANAGER_WS=' + json.dumps(config) + ';' + probe + '</script>').encode()
                self.ledger.record('ws-page', mode=mode, peer=peer)
            BASE.answer(channel, b'200 OK', body)
        except (OSError, ValueError, KeyError, UnicodeError, IndexError):
            self.ledger.record('ws-http-refused');
            try: BASE.answer(channel, b'400 Bad Request', b'')
            except OSError: pass
        finally: self.untrack(channel)

    def websocket_request(self, channel):
        self.track(channel); channel.settimeout(12); key = uuid.uuid4().hex
        try:
            pieces = BASE.header(channel).split(b'\r\n'); first = pieces[0].split(); require(len(first) == 3 and first[0] == b'GET')
            mode, query = self.parse(first[1].decode('ascii'), '/echo', ('phase',)); phase = query['phase']
            fields = {}
            for line in pieces[1:]:
                if not line: continue
                name, value = line.split(b':', 1); name = name.strip().lower(); require(name not in fields); fields[name] = value.strip()
            require(fields.get(b'upgrade', b'').lower() == b'websocket' and b'upgrade' in [x.strip() for x in fields.get(b'connection', b'').lower().split(b',')]
                    and fields.get(b'sec-websocket-version') == b'13' and len(base64.b64decode(fields.get(b'sec-websocket-key', b''), validate=True)) == 16)
            require(fields.get(b'origin') == ('http://127.0.0.1:' + str(self.origin.server_address[1])).encode())
            peer = self.request_peer(channel)
            with self.control_lock: require(mode == self.active_mode and phase == self.phase_name)
            self.ledger.record('ws-handshake', mode=mode, phase=phase, eventID=key, peer=peer)
            accept = base64.b64encode(hashlib.sha1(fields[b'sec-websocket-key'] + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            channel.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
            while not self.stopping.is_set():
                opcode, payload = client_frame(channel)
                if opcode == 8: channel.sendall(frame(payload, 8)); break
                if opcode == 9: channel.sendall(frame(payload, 10)); continue
                require(payload == ('own:' + self.nonces[mode] + ':' + phase).encode())
                channel.sendall(frame(payload)); self.ledger.record('ws-echo', mode=mode, phase=phase, eventID=key)
        except (OSError, ValueError, KeyError, UnicodeError, IndexError): self.ledger.record('ws-connection-ended', eventID=key)
        finally: self.ledger.record('ws-closed', eventID=key); self.untrack(channel)

    def proxy_request(self, client):
        upstream = None; peer_port = None; self.track(client); client.settimeout(15)
        try:
            lines = BASE.header(client).split(b'\r\n'); pieces = lines[0].split(); require(len(pieces) == 3)
            auth = b'Proxy-Authorization: Basic ' + base64.b64encode((BASE.QA_USER + ':' + BASE.QA_PASSWORD).encode())
            if auth not in lines:
                client.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="Owned WS"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'); self.ledger.record('ws-auth-refused'); return
            require(pieces[0] == b'CONNECT'); host, port = pieces[1].decode('ascii').rsplit(':', 1); port = int(port)
            ws = host == '127.0.0.1' and port == self.websocket.server_address[1]
            local = ws or host == '127.0.0.1' and port == self.origin.server_address[1]
            require(local or host in self.public_tls_hosts and port == 443)
            with self.control_lock:
                if ws and self.phase_name == 'blocked':
                    self.ledger.record('ws-connect-refused', mode=self.active_mode); BASE.answer(client, b'502 Bad Gateway', b''); return
            custody = self.peer_inspector(client, False) if local and self.peer_inspector else None
            require(not local or custody is not None)
            upstream = self.open_upstream(host, port); self.track(upstream)
            if local:
                peer_port = upstream.getsockname()[1]
                with self.control_lock:
                    # The connect may overlap the fault transition. Do not
                    # publish a new WS tunnel after the cut took its snapshot.
                    require(not ws or self.phase_name != 'blocked')
                    self.peers[peer_port] = dict(custody=custody)
                    if ws: self.ws_channels.update((client, upstream))
            client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            while not self.stopping.is_set():
                ready, _, _ = select.select((client, upstream), (), (), .2)
                for source in ready:
                    chunk = source.recv(16384)
                    if not chunk: return
                    (upstream if source is client else client).sendall(chunk)
        except (OSError, ValueError, KeyError, IndexError): self.ledger.record('ws-proxy-ended')
        finally:
            with self.control_lock:
                if peer_port is not None: self.peers.pop(peer_port, None)
                self.ws_channels.discard(client); self.ws_channels.discard(upstream)
            if upstream is not None: self.untrack(upstream); upstream.close()
            self.untrack(client)

    def close(self):
        if hasattr(self, 'websocket'): self.websocket.shutdown(); self.websocket.server_close()
        return super().close()
