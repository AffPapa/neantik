#!/usr/bin/env python3
"""Owned shipping-manager GUI route fixture; no CLI result implies browser PASS.

GUI operator configures only the two named synthetic profiles and memory-only
audit credentials. The proxy may tunnel TLS to the manager's existing GeoIP
providers, unchanged; local origin requests are counted independently. No raw
URLs, IPs, headers, provider bodies or credentials enter the public ledger.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import socket
import socketserver
import stat
import subprocess
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit, urlencode

# Public dummy data for this loopback-only fixture, never a user's credential.
QA_USER = "owned-fixture-user"
QA_PASSWORD = "not-a-real-proxy-password"
PHASES = ("proxy-success", "upstream-refused", "upstream-cut", "proxy-recovered", "direct-control")
OWNED_HTTPS_ENDPOINT = 'https://browser.free/api/route-qa/https'


def verify_https_receipt(query, nonce, now=None):
    """The fixed public signer proves the HTTPS response, never the TLS route alone."""
    if set(query) != {'r', 's'} or any(len(value) != 1 for value in query.values()):
        return False
    document = dict(r=query['r'][0], s=query['s'][0], nonce=nonce,
                    now=int(time.time()) if now is None else now)
    verifier = Path(__file__).with_name('verify-owned-https-receipt.mjs')
    try:
        result = subprocess.run(['node', str(verifier)], input=json.dumps(document),
                                capture_output=True, text=True, timeout=3)
        return result.returncode == 0 and json.loads(result.stdout) == {'valid': True}
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def private_json(path, data):
    temporary = path.with_name(path.name + '.new')
    with temporary.open('w') as stream:
        os.chmod(temporary, 0o600)
        json.dump(data, stream, indent=2); stream.write('\n')
    temporary.replace(path)


def header(channel):
    result = bytearray()
    while not result.endswith(b'\r\n\r\n'):
        if len(result) >= 16384:
            raise ValueError('bounded-header')
        chunk = channel.recv(1)
        if not chunk:
            raise ValueError('incomplete-header')
        result.extend(chunk)
    return bytes(result)


def answer(channel, status, body):
    channel.sendall(b'HTTP/1.1 ' + status + b'\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)


class Ledger:
    def __init__(self, path):
        self.path, self.lock, self.events = path, threading.Lock(), []

    def record(self, kind, **values):
        with self.lock:
            self.events.append(dict(kind=kind, at=time.monotonic(), **values))
            private_json(self.path, self.events)


class Fixture:
    public_tls_hosts = {'ipapi.co', 'ipwho.is', 'free.freeipapi.com'}

    def __init__(self, root, *, owned_https=False):
        self.root = root
        self.owned_https = owned_https
        self.ledger = Ledger(root / 'observations.json')
        self.nonces = {phase: uuid.uuid4().hex for phase in PHASES}
        self.https_nonces = {phase: uuid.uuid4().hex + uuid.uuid4().hex for phase in PHASES} if owned_https else {}
        self.hop = uuid.uuid4().hex
        self.sockets, self.socket_lock = set(), threading.Lock()
        self.local_sockets = set()
        self.https_sockets = set()
        self.https_acknowledged = set()
        self.stopping = threading.Event()
        owner = self

        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            block_on_close = False
            def handle_error(self, *_): owner.ledger.record('handler-failure')

        class Origin(socketserver.BaseRequestHandler):
            def handle(self): owner.origin_request(self.request)

        class Proxy(socketserver.BaseRequestHandler):
            def handle(self): owner.proxy_request(self.request)

        self.origin = Server(('127.0.0.1', 0), Origin)
        self.proxy = Server(('127.0.0.1', 0), Proxy)
        self.threads = [threading.Thread(target=x.serve_forever, daemon=True) for x in (self.origin, self.proxy)]
        for thread in self.threads: thread.start()
        self.cut_thread = threading.Thread(target=self.watch_cut, daemon=True)
        self.cut_thread.start()

    def url(self, phase):
        return 'http://127.0.0.1:' + str(self.origin.server_address[1]) + '/owned-route?phase=' + phase + '&nonce=' + self.nonces[phase]

    def https_url(self, phase):
        if not self.owned_https or phase not in PHASES: raise ValueError('https-fixture-disabled-or-invalid-phase')
        callback = 'http://127.0.0.1:' + str(self.origin.server_address[1]) + '/__neantik_route/ack'
        return OWNED_HTTPS_ENDPOINT + '?' + urlencode(dict(nonce=self.https_nonces[phase], callback=callback))

    def https_phase(self):
        """Only the private operator selects phase; visiting a URL cannot reset it."""
        control = self.root / 'https-phase'
        if not self.owned_https: return None
        descriptor = None
        try:
            descriptor = os.open(control, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 64:
                return None
            value = os.read(descriptor, 65)
            if len(value) > 64: return None
            phase = value.decode('ascii').strip()
        except (OSError, ValueError): return None
        finally:
            if descriptor is not None: os.close(descriptor)
        return phase if phase in PHASES else None

    def https_callback(self, target, protected):
        parsed = urlsplit(target)
        if parsed.path != '/__neantik_route/ack': return None
        if not self.owned_https or len(target) > 4096: return False
        query = parse_qs(parsed.query, keep_blank_values=True)
        # Match the active phase's nonce against a cryptographically signed
        # response. Raw payload/signature never enter the redacted ledger.
        phase = self.https_phase()
        valid = phase is not None and verify_https_receipt(query, self.https_nonces[phase])
        if valid:
            with self.socket_lock:
                valid = phase not in self.https_acknowledged and phase == self.https_phase()
                if valid: self.https_acknowledged.add(phase)
        self.ledger.record('owned-https-receipt', phase=phase, valid=valid, throughOwnedUpstream=protected)
        return valid

    def phase(self, target):
        parsed = urlsplit(target)
        if parsed.path not in ('/owned-route', '/owned-stream'):
            return None
        query = parse_qs(parsed.query)
        phases, nonces = query.get('phase', []), query.get('nonce', [])
        if len(phases) != 1 or len(nonces) != 1:
            return None
        phase = phases[0]
        return phase if phase in self.nonces and self.nonces[phase] == nonces[0] else None

    def origin_request(self, channel):
        self.track(channel)
        channel.settimeout(10)
        try:
            request = header(channel)
            pieces = request.split(b'\r\n', 1)[0].split()
            if len(pieces) != 3 or pieces[0] != b'GET':
                raise ValueError('request-method')
            protected = b'X-NeAntik-Owned-Hop: ' + self.hop.encode() in request.split(b'\r\n')
            callback = self.https_callback(pieces[1].decode('ascii'), protected)
            if callback is not None:
                answer(channel, b'200 OK' if callback else b'400 Bad Request',
                       b'<title>OWNED HTTPS RECEIPT</title><h1>Verified owned HTTPS response</h1>' if callback else b'')
                return
            phase = self.phase(pieces[1].decode('ascii'))
            if phase is None:
                answer(channel, b'404 Not Found', b''); return
            if urlsplit(pieces[1].decode('ascii')).path == '/owned-stream':
                self.ledger.record('origin-stream', phase=phase, throughOwnedUpstream=protected)
                channel.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n')
                until = time.monotonic() + 180
                first = True
                while not self.stopping.wait(.25) and time.monotonic() < until:
                    body = b'owned heartbeat\n'
                    channel.sendall(format(len(body), 'x').encode() + b'\r\n' + body + b'\r\n')
                    if first:
                        first = False
                        self.ledger.record('stream-first-heartbeat', phase=phase, throughOwnedUpstream=protected)
                        # Arm before opening the page: cut only after a protected
                        # connection has actually sent data, never an idle socket.
                        arm = self.root / 'arm-cut-on-stream'
                        if protected and phase == 'proxy-success' and arm.exists():
                            arm.unlink()
                            (self.root / 'cut-upstream').touch(mode=0o600)
                            self.ledger.record('automatic-cut-armed', phase=phase)
                channel.sendall(b'0\r\n\r\n'); return
            self.ledger.record('origin', phase=phase, throughOwnedUpstream=protected)
            label = 'OWNED PROXY ROUTE' if protected else 'OWNED DIRECT CONTROL'
            links = ''.join('<p><a href="' + self.url(p) + '">' + p + '</a></p>' for p in PHASES)
            stream = ''
            if phase == 'proxy-success':
                target = self.url(phase).replace('/owned-route?', '/owned-stream?')
                stream = '<script>fetch(' + json.dumps(target) + ',{cache:"no-store"}).then(async r=>{const reader=r.body.getReader();for(;;){const next=await reader.read();if(next.done)break;document.body.dataset.ownedStream="received";}}).catch(()=>{document.body.dataset.ownedStream="closed";});</script>'
            answer(channel, b'200 OK', ('<!doctype html><title>' + label + '</title><h1>' + label + '</h1><p>' + phase + '</p>' + links + stream).encode())
        except (OSError, ValueError):
            self.ledger.record('origin-protocol-failure')
        finally:
            self.untrack(channel)

    def track(self, channel):
        with self.socket_lock: self.sockets.add(channel)

    def untrack(self, channel):
        with self.socket_lock:
                self.sockets.discard(channel); self.local_sockets.discard(channel); self.https_sockets.discard(channel)

    def watch_cut(self):
        previous = False
        while not self.stopping.wait(.1):
            active = (self.root / 'cut-upstream').exists()
            if active and not previous:
                with self.socket_lock:
                    local_channels, tls_channels = list(self.local_sockets), list(self.https_sockets)
                    channels = local_channels + tls_channels
                for channel in channels:
                    try: channel.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
                self.ledger.record('cut-active-local-channels', channels=len(local_channels))
                if self.owned_https:
                    self.ledger.record('cut-active-owned-tls-channels', channels=len(tls_channels), phase=self.https_phase())
            previous = active

    def owned_local_destination(self, host, port):
        """Only the fixed origin by default; DNS fixtures override this hook."""
        return host == '127.0.0.1' and port == self.origin.server_address[1]

    def open_upstream(self, host, port):
        return socket.create_connection((host, port), timeout=12)

    def proxy_request(self, client):
        upstream = None
        self.track(client)
        try:
            client.settimeout(15)
            request = header(client)
            pieces = request.split(b'\r\n', 1)[0].split()
            if len(pieces) != 3: raise ValueError('proxy-request')
            auth = b'Proxy-Authorization: Basic ' + base64.b64encode((QA_USER + ':' + QA_PASSWORD).encode())
            if auth not in request.split(b'\r\n'):
                self.ledger.record('auth-challenge')
                client.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="Owned fixture"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'); return
            if pieces[0] == b'CONNECT':
                host, port = pieces[1].decode('ascii').rsplit(':', 1)
                port = int(port); forwarded = None
            elif pieces[0] == b'GET':
                parsed = urlsplit(pieces[1].decode('ascii'))
                if parsed.scheme != 'http': raise ValueError('scheme')
                host, port = parsed.hostname, parsed.port or 80
                path = (parsed.path or '/') + ('?' + parsed.query if parsed.query else '')
                forwarded = request.replace(pieces[1], path.encode(), 1)
            else:
                raise ValueError('method')
            local = self.owned_local_destination(host, port)
            owned_tls = self.owned_https and host == 'browser.free' and port == 443 and forwarded is None
            if not (local or owned_tls or host in self.public_tls_hosts and port == 443 and forwarded is None):
                raise ValueError('destination-not-owned-or-allowlisted')
            if (local or owned_tls) and (self.root / 'drop-upstream').exists():
                self.ledger.record('upstream-refused', purpose='owned-https' if owned_tls else 'local-http', phase=self.https_phase() if owned_tls else None)
                answer(client, b'502 Bad Gateway', b''); return
            if (local or owned_tls) and (self.root / 'cut-upstream').exists():
                self.ledger.record('upstream-tcp-cut', purpose='owned-https' if owned_tls else 'local-http', phase=self.https_phase() if owned_tls else None)
                client.shutdown(socket.SHUT_RDWR); return
            upstream = self.open_upstream(host, port)
            self.track(upstream)
            if forwarded is None:
                client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            if local:
                with self.socket_lock: self.local_sockets.update((client, upstream))
                forwarded = forwarded if forwarded is not None else header(client)
                local_target = forwarded.split(b'\r\n', 1)[0].split()[1].decode('ascii')
                phase = self.phase(local_target)
                callback_target = self.owned_https and urlsplit(local_target).path == '/__neantik_route/ack'
                if phase is None and not callback_target: raise ValueError('owned-nonce')
                forwarded = forwarded[:-2] + b'X-NeAntik-Owned-Hop: ' + self.hop.encode() + b'\r\n\r\n'
                upstream.sendall(forwarded)
                self.ledger.record('upstream-http', phase=phase, stream=urlsplit(local_target).path == '/owned-stream', ownedHTTPSCallback=callback_target)
            elif owned_tls:
                with self.socket_lock: self.https_sockets.update((client, upstream))
                self.ledger.record('owned-https-tunnel', phase=self.https_phase())
            else:
                self.ledger.record('geoip-preflight-tunnel')
            until = time.monotonic() + (180 if local else 55)
            while not self.stopping.is_set() and time.monotonic() < until:
                ready, _, _ = select.select([client, upstream], [], [], .25)
                for source in ready:
                    chunk = source.recv(16384)
                    if not chunk: return
                    (upstream if source is client else client).sendall(chunk)
        except (OSError, ValueError, IndexError):
            self.ledger.record('proxy-operation-failure')
        finally:
            if upstream is not None:
                self.untrack(upstream); upstream.close()
            self.untrack(client)

    def close(self):
        self.stopping.set()
        with self.socket_lock: channels = list(self.sockets)
        for channel in channels:
            try: channel.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        for server in (self.origin, self.proxy): server.shutdown(); server.server_close()
        for thread in self.threads: thread.join(3)
        self.cut_thread.join(3)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with self.socket_lock:
                if not self.sockets: break
            time.sleep(.05)
        with self.socket_lock: channels_drained = not self.sockets
        return channels_drained and not any(thread.is_alive() for thread in [*self.threads, self.cut_thread])


def owned_browser_pids(rows, browser, data, uid):
    """Select exact QA runtime/data custody; never identify by bundle ID alone.

    Raw ps command lines stay in memory. Helpers are descendants of the main
    browser and settle with it; only the bound main process receives SIGTERM.
    """
    result = []
    pattern = re.compile(r'(?:^|\s)--user-data-dir=' + re.escape(str(data)) + r'/[^\s]+(?:\s|$)')
    for row in rows:
        fields = row.strip().split(None, 2)
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        pid, owner, command = fields
        if (int(owner) == uid and command.startswith(str(browser) + ' ')
                and pattern.search(command) and '--use-mock-keychain' in command.split()):
            result.append(int(pid))
    return result


def drain_owned_browsers(app, data, timeout=10):
    """Deadline cleanup for an abandoned synthetic session, not a graceful-exit test."""
    import signal
    browser = app / 'Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser'
    def inventory():
        return subprocess.check_output(['/bin/ps', '-axo', 'pid=,uid=,command='], text=True).splitlines()
    pids = owned_browser_pids(inventory(), browser, data, os.getuid())
    for pid in pids:
        # Recheck immediately before mutation; a reused PID is never sufficient.
        if pid in owned_browser_pids(inventory(), browser, data, os.getuid()):
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
    deadline = time.monotonic() + timeout
    while True:
        rows = inventory()
        # Count children as well, without emitting paths/argv from ps.
        remaining = sum(str(app / 'Contents/Resources/NeAntik Browser.app') in row
                        and str(data) + '/' in row for row in rows)
        if not remaining or time.monotonic() >= deadline:
            return dict(termination='SIGTERM of custody-bound QA main processes',
                        signaledMainProcesses=len(pids), ownedRuntimeProcessesRemaining=remaining,
                        gracefulCloseQualified=False)
        time.sleep(.1)


def seed_profiles(executable, data_root, urls):
    """Only profile_create: a separate MCP process has no audit Keychain backend."""
    process = subprocess.Popen([str(executable), '--neantik-mcp-stdio', '--data-root', str(data_root), '--allow-profile-management'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    sequence = 0
    def rpc(method, params):
        nonlocal sequence
        sequence += 1
        process.stdin.write((json.dumps(dict(jsonrpc='2.0', id=sequence, method=method, params=params)) + '\n').encode()); process.stdin.flush()
        deadline = time.monotonic() + 10; line = bytearray()
        while time.monotonic() < deadline:
            readable, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not readable: break
            char = os.read(process.stdout.fileno(), 1)
            if not char: break
            line.extend(char)
            if len(line) > 262144: raise ValueError('MCP-output-bound')
            if char == b'\n':
                message = json.loads(line); line.clear()
                if message.get('id') == sequence:
                    if 'error' in message or message.get('result', {}).get('isError'): raise ValueError('MCP-operation-refused')
                    return message['result']
        raise ValueError('MCP-response-timeout')
    try:
        rpc('initialize', dict(protocolVersion='2025-11-25', capabilities={}, clientInfo=dict(name='owned-route-qa', version='1')))
        process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); process.stdin.flush()
        profiles = []
        for name, phase in [('QA route proxy', 'proxy-success'), ('QA route direct', 'direct-control')]:
            result = rpc('tools/call', dict(name='profile_create', arguments=dict(name=name, changes=dict(startURL=urls[phase], tags=['owned-route-qa']))))
            value = result.get('structuredContent')
            if value is None: value = json.loads(next(x['text'] for x in result['content'] if x.get('type') == 'text'))
            profiles.append(dict(id=value['id'], name=value['name']))
        process.stdin.close()
        if process.wait(5) != 0: raise ValueError('MCP-cleanup')
        return profiles
    finally:
        if process.poll() is None: process.terminate(); process.wait(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--candidate-manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='new private output directory')
    parser.add_argument('--duration', type=int, default=900)
    parser.add_argument('--owned-https', action='store_true', help='fixed browser.free signed response; no custom endpoint/trust override')
    args = parser.parse_args()
    if not 60 <= args.duration <= 1800: raise ValueError('duration-bound')
    app = args.app.resolve(); executable = app / 'Contents/MacOS/NeAntik'
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    manifest = json.loads(args.candidate_manifest.read_text())
    for item in manifest['criticalFiles'].values():
        relative = Path(item['bundlePath'])
        if relative.is_absolute() or '..' in relative.parts or (app / relative).is_symlink() or digest(app / relative) != item['sha256']:
            raise ValueError('candidate-byte-binding')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['python3', '-B', str(Path(__file__).resolve().parents[1] / 'direct-candidate-manifest.py'),
                    'verify', '--app', str(app), '--manifest', str(args.candidate_manifest.resolve()),
                    '--release-channel', manifest['releaseChannel']], check=True, stdout=subprocess.DEVNULL)
    output = args.output.resolve(); output.mkdir(mode=0o700)
    root = Path('/private/tmp/neantik-update-audit-' + str(uuid.uuid4())); root.mkdir(mode=0o700)
    copied_manifest = root / 'candidate-manifest.json'; shutil.copyfile(args.candidate_manifest, copied_manifest); copied_manifest.chmod(0o600)
    data = root / 'manager-data'; data.mkdir(mode=0o700)
    fixture = Fixture(root, owned_https=args.owned_https); manager = None
    cleanup = None
    try:
        urls = {phase: fixture.url(phase) for phase in PHASES}
        https_urls = {phase: fixture.https_url(phase) for phase in PHASES} if args.owned_https else None
        if args.owned_https:
            (root / 'https-phase').write_text('proxy-success'); (root / 'https-phase').chmod(0o600)
        profiles = seed_profiles(executable, data, https_urls if https_urls is not None else urls)
        state = dict(app=str(app), executable=str(executable), root=str(root), data=str(data), manifest=str(copied_manifest),
                     output=str(root / 'update-audit.json'), proxyPort=fixture.proxy.server_address[1], urls=urls, profiles=profiles,
                     managerSHA256=digest(executable), version=metadata['CFBundleShortVersionString'], build=metadata['CFBundleVersion'])
        state['fixtureSHA256'] = digest(Path(__file__))
        state['candidateManifestSHA256'] = digest(copied_manifest)
        state['httpsURLs'] = https_urls
        with (root / 'manager.log').open('wb') as log:
            os.chmod(root / 'manager.log', 0o600)
            manager = subprocess.Popen([str(executable), '--neantik-release-update-audit', '--candidate-manifest',
                str(copied_manifest).replace('/private/tmp/', '/tmp/'), '--output', state['output']], stdout=log, stderr=log, start_new_session=True)
            state['managerPID'] = manager.pid
            private_json(output / 'private-state.json', state)
            print(json.dumps(dict(stage='manager-process-spawned', ownedPID=manager.pid, syntheticProfiles=2,
                                  authenticatedGUIVerified=False, authorityEnrollmentPerformedByFixture=False)), flush=True)
            deadline = time.monotonic() + args.duration
            while manager.poll() is None and not (root / 'finish-fixture').exists() and time.monotonic() < deadline: time.sleep(.25)
            if manager.poll() is None: manager.terminate(); manager.wait(10)
        state['managerExitCode'] = manager.returncode
        private_json(output / 'private-state.json', state)
    finally:
        if manager is not None and manager.poll() is None: manager.terminate(); manager.wait(10)
        try:
            cleanup = drain_owned_browsers(app, data)
        except (OSError, subprocess.SubprocessError):
            cleanup = dict(status='process-custody-check-unavailable', gracefulCloseQualified=False)
        drained = fixture.close()
        private_json(output / 'fixture-ledger.json', dict(schemaVersion=1, events=fixture.ledger.events,
            serverThreadsDrained=drained, managerExitCode=manager.returncode if manager else None,
            runtimeCleanup=cleanup,
            authorityEnrollmentPerformedByFixture=False,
            authorityRetirementQualified=False,
            scope='independent fixture counters; caller enrollment and retirement, GUI/session/negative controls require separate qualification'))
    print(json.dumps(dict(stage='fixture-closed', managerExitCode=manager.returncode, serverThreadsDrained=drained)), flush=True)
    if manager.returncode != 0 or not drained: raise SystemExit(1)


if __name__ == '__main__': main()
