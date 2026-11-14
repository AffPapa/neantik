#!/usr/bin/env python3
"""Check one frozen Chromium runtime with disposable headless profiles."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import zipfile


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_extracted_identity(archive: Path, stage: Path, framework_version: str) -> None:
    # The signed manager and its resource seal bind nested code identities.
    # Deep signature verification separately checks those nested signatures.
    framework = ('NeAntik.app/Contents/Resources/NeAntik Browser.app/Contents/Frameworks/'
                 'NeAntik Browser Framework.framework/Versions/'
                 f'{framework_version}/NeAntik Browser Framework')
    files = ('NeAntik.app/Contents/MacOS/NeAntik',
             'NeAntik.app/Contents/_CodeSignature/CodeResources',
             'NeAntik.app/Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser',
             framework)
    with zipfile.ZipFile(archive) as package:
        for name in files:
            with package.open(name) as stream:
                expected = hashlib.file_digest(stream, 'sha256').hexdigest()
            if digest(stage / name) != expected:
                raise ValueError('extracted signed identity differs from the ZIP')


def retained_stage(archive: Path) -> Path:
    stage = archive.parent
    metadata = stage.lstat()
    if (archive.resolve(strict=True) != archive or stage.parent != Path('/private/tmp')
            or not stage.name.startswith('neantik-owned-webkit-successor-qa-')
            or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700):
        raise ValueError('retained bundle requires a private successor QA stage')
    return stage


@contextmanager
def route_fixture(nonce: str, *, manager_preflight: bool = False, stun_port: int | None = None):
    class FixtureServer(ThreadingHTTPServer):
        daemon_threads = False

        def get_request(self):
            client, address = super().get_request()
            client.settimeout(2)
            return client, address

    counts = dict(A=0, B=0, direct=0, refused=0)
    if manager_preflight:
        counts['preflight'] = 0
    # Balanced profiles block literal loopback URLs before proxy routing.
    # This synthetic name is served only by the owned proxy; it never resolves.
    hostname = f'neantik-{nonce}.invalid'
    refuse_a = threading.Event()
    state = f'profile-state-{nonce}'
    document = f"""<!doctype html><body id="probe">not-executed<script>
const key = {json.dumps(state)};
const result = localStorage.getItem(key) === 'written' ? 'restored' : 'fresh';
localStorage.setItem(key, 'written');
document.body.textContent = {json.dumps(nonce + ':')} + result;
document.title = document.body.textContent;
</script>""".encode()
    rtc_document = document + f"""<script>
(async () => {{
  const peer = new RTCPeerConnection({{iceServers: [{{urls: 'stun:127.0.0.1:{stun_port}'}}]}});
  let timer;
  try {{
    peer.createDataChannel('neantik-qa');
    await peer.setLocalDescription(await peer.createOffer());
    await new Promise((resolve, reject) => {{
      const complete = () => {{ if (peer.iceGatheringState === 'complete') resolve(); }};
      peer.addEventListener('icegatheringstatechange', complete);
      timer = setTimeout(() => reject(new Error('ICE timeout')), 12000);
      complete();
    }});
    document.title += ':rtc-complete';
  }} catch {{
    document.title += ':rtc-incomplete';
  }} finally {{
    clearTimeout(timer);
    peer.close();
  }}
}})();
</script>""".encode() if stun_port is not None else None

    def handler(route):
        class Proxy(BaseHTTPRequestHandler):
            def do_GET(self):
                if (manager_preflight and route == 'A'
                        and self.path == 'http://neantik-probe.invalid/health'
                        and self.headers.get('Host') == 'neantik-probe.invalid'):
                    counts['preflight'] += 1
                    self.respond(b'NEANTIK_LOOPBACK_QA_OK\n', 'text/plain')
                    return
                try:
                    target = urllib.parse.urlsplit(self.path)
                except ValueError:
                    target = None
                rtc = rtc_document is not None and target is not None and target.query == 'rtc=1'
                query = 'rtc=1' if rtc else ''
                expected = ('', '', '/', query, '') if route == 'direct' else ('http', authority, '/', query, '')
                if (target is None or (target.scheme, target.netloc, target.path, target.query, target.fragment)
                        != expected or self.headers.get('Host') != authority):
                    self.send_error(403)
                    return
                if route == 'A' and refuse_a.is_set():
                    counts['refused'] += 1
                    if manager_preflight:
                        self.send_response(502)
                        self.send_header('Content-Type', 'text/html')
                        self.end_headers()
                        self.wfile.write(f'<title>{nonce}:refused</title>'.encode())
                    else:
                        self.send_error(502)
                    return
                counts[route] += 1
                self.respond(rtc_document if rtc else document, 'text/html')

            def respond(self, payload, content_type):
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_CONNECT(self):
                self.send_error(403)

            def log_message(self, *_):
                pass
        return Proxy

    servers = {}
    threads = []
    try:
        for route in ('direct', 'A', 'B'):
            server = FixtureServer(('127.0.0.1', 0), handler(route))
            servers[route] = server
            if route == 'direct':
                authority = f'{hostname}:{server.server_port}'
        for server in servers.values():
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)
        yield (f'http://{authority}/', counts,
               {key: servers[key].server_port for key in ('A', 'B')}, refuse_a)
    finally:
        for server in servers.values():
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=2)


def wait_for_runtime_exit(runtime: Path) -> bool:
    prefix = str(runtime / 'Contents') + '/'
    deadline = time.monotonic() + 3
    while True:
        processes = subprocess.check_output(['/bin/ps', '-ax', '-o', 'comm='], text=True, timeout=2)
        if not any(line.lstrip().startswith(prefix) for line in processes.splitlines()):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(.05)


def run_phase(binary: Path, stage: Path, profile: Path, proxy_port: int | None, target: str,
              nonce: str, expected_state: str | None) -> dict:
    home = stage / 'home'
    environment = {'HOME': str(home), 'TMPDIR': str(stage), 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'}
    arguments = [
        str(binary), '--headless', '--disable-gpu', '--renderer-process-limit=1',
        '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
        '--disable-component-update', '--disable-sync', '--disable-extensions', '--use-mock-keychain',
        f'--host-resolver-rules=MAP {urllib.parse.urlsplit(target).hostname} 127.0.0.1, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
        f'--user-data-dir={profile}',
        f'--proxy-server=http://127.0.0.1:{proxy_port}' if proxy_port is not None else '--no-proxy-server',
        '--proxy-bypass-list=<-loopback>', '--dump-dom', '--timeout=5000', target,
    ]
    with subprocess.Popen(arguments, env=environment, cwd=stage, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, start_new_session=True) as child:
        try:
            stdout, stderr = child.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=5)
            return {'status': 'timeout', 'actualPage': False}
        actual_page = f'<body id="probe">{nonce}:'.encode() in stdout
        expected_page = f'<body id="probe">{nonce}:{expected_state}</body>'.encode() in stdout
        outcome = (not actual_page and child.returncode >= 0 if expected_state is None
                   else expected_page and child.returncode == 0)
        return {'status': 'PASS' if outcome else 'FAIL',
                'exit': child.returncode, 'actualPage': actual_page,
                'launchServicesDiagnostic': b'LaunchServices' in stderr}


def serve_manager_fixture() -> int:
    from importlib import import_module

    stun = import_module('manager-webrtc-fixture').OwnedSTUN()
    try:
        counts = serve_manager_routes(stun, stun.canary())
    finally:
        terminal = stun.close()
    if counts is None:
        return 1
    print(json.dumps({'status': 'fixture-stopped', 'counts': counts,
                      'udp': {'requests': terminal['browserRequests'], 'invalid': terminal['invalidRequests']},
                      'stunDrained': terminal['closed'] and terminal['threadDrained']}), flush=True)
    return 0 if terminal['threadDrained'] else 1


def serve_manager_routes(stun, canary) -> int:
    nonce = secrets.token_hex(12)
    with route_fixture(nonce, manager_preflight=True, stun_port=stun.port) as (target, counts, ports, refuse_a):
        print(json.dumps({'status': 'ready', 'browserURL': target, 'proxyPort': ports['A'],
                          'pageTitlePrefix': nonce + ':', 'stunCanary': canary}), flush=True)
        for line in sys.stdin:
            command = line.strip()
            if command == 'stop':
                return counts
            if command == 'refuse':
                refuse_a.set()
            elif command == 'recover':
                refuse_a.clear()
            elif command != 'status':
                print(json.dumps({'status': 'invalid-command'}), flush=True)
                continue
            with stun.lock:
                udp = {'requests': stun.requests, 'invalid': stun.invalid}
            print(json.dumps({'status': 'snapshot', 'counts': counts, 'refusing': refuse_a.is_set(),
                              'udp': udp}), flush=True)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', type=Path)
    parser.add_argument('--sha256')
    parser.add_argument('--serve-manager-fixture', action='store_true',
                        help='Serve loopback only. Commands on stdin are status, refuse, recover and stop.')
    parser.add_argument('--resume', type=Path, help='Reuse an extracted stage whose first admission was refused')
    parser.add_argument('--retained-bundle', action='store_true',
                        help='Read the existing signed app beside the private successor archive')
    parser.add_argument('--check-only', action='store_true', help='Bind bytes without starting Chromium')
    args = parser.parse_args()
    if args.serve_manager_fixture:
        if args.zip or args.sha256 or args.resume or args.retained_bundle or args.check_only:
            parser.error('--serve-manager-fixture is standalone')
        return serve_manager_fixture()
    if args.zip is None or args.sha256 is None:
        parser.error('--zip and --sha256 are required for candidate checks')
    if args.resume is not None and args.retained_bundle:
        parser.error('--resume and --retained-bundle cannot be combined')
    if digest(args.zip) != args.sha256:
        parser.error('ZIP SHA-256 mismatch')
    if args.retained_bundle:
        app_stage = retained_stage(args.zip)
        stage = Path(tempfile.mkdtemp(prefix='neantik-chromium-headless-', dir='/private/tmp'))
        report_name = 'result.json'
    elif args.resume is None:
        stage = Path(tempfile.mkdtemp(prefix='neantik-chromium-headless-', dir='/private/tmp'))
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(args.zip), str(stage)], check=True, timeout=60)
        app_stage = stage
        report_name = 'result.json'
    else:
        stage = args.resume
        app_stage = stage
        metadata = stage.lstat()
        if (stage.parent != Path('/private/tmp') or not stage.name.startswith('neantik-chromium-headless-')
                or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) != 0o700):
            parser.error('resume requires a private headless stage')
        previous = json.loads((stage / 'result.json').read_bytes())
        if (previous['status'] != 'not-run' or previous['zipSHA256'] != args.sha256
                or os.path.lexists(stage / 'native-attempt-consumed')):
            parser.error('stage is not an unconsumed admission refusal')
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        report_name = f'result-{stamp}.json'
    print(stage, flush=True)
    app = app_stage / 'NeAntik.app'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, timeout=30)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    runtime = app / 'Contents/Resources/NeAntik Browser.app'
    binary = runtime / 'Contents/MacOS/NeAntik Browser'
    with (runtime / 'Contents/Info.plist').open('rb') as stream:
        runtime_info = plistlib.load(stream)
    version = runtime_info['CFBundleShortVersionString']
    if not isinstance(version, str) or len(version.split('.')) != 4 or not all(
            part.isascii() and part.isdecimal() for part in version.split('.')):
        parser.error('invalid Chromium framework version')
    framework = runtime / 'Contents/Frameworks/NeAntik Browser Framework.framework'
    if (framework / 'Versions/Current').resolve(strict=True) != framework / 'Versions' / version:
        parser.error('Chromium framework Current does not resolve to the archived version')
    check_extracted_identity(args.zip, app_stage, version)
    report = {'scope': 'nested Chromium, headless CLI, synthetic origin and profiles, loopback HTTP',
              'candidateKind': 'private-successor' if args.retained_bundle else 'extracted-archive',
              'zipSHA256': args.sha256, 'managerVersion': info['CFBundleShortVersionString'],
              'managerBuild': info['CFBundleVersion'], 'runtimeVersion': version,
              'managerExecutableSHA256': digest(app / 'Contents/MacOS/NeAntik'),
              'runtimeFrameworkSHA256': digest(framework / 'Versions' / version / 'NeAntik Browser Framework'),
              'runtimeExecutableSHA256': digest(binary), 'phases': []}

    def save():
        with (stage / report_name).open('x') as stream:
            stream.write(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))

    if args.check_only:
        report['status'] = 'static-pass'
        save()
        return 0

    admission = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve().parents[1] /
                                'native-qa-readiness.py'), '--check'], capture_output=True, check=False, timeout=10)
    report['admission'] = json.loads(admission.stdout)
    if admission.returncode or report['admission'].get('eligibleForAttempt') is not True:
        report['status'] = 'not-run'
        save()
        return 75

    (stage / 'native-attempt-consumed').touch(mode=0o600, exist_ok=False)
    (stage / 'home').mkdir(mode=0o700)
    profiles = {key: stage / f'profile-{key}' for key in ('A', 'B', 'direct')}
    for profile in profiles.values():
        profile.mkdir(mode=0o700)
    nonce = secrets.token_hex(12)
    with route_fixture(nonce) as (target, counts, ports, refuse_a):
        phases = [
            ('direct-control', 'direct', 'fresh', 'direct'),
            ('A1', 'A', 'fresh', 'A'),
            ('B1', 'B', 'fresh', 'B'),
            ('A-refused', 'A', None, 'refused'),
            ('A2', 'A', 'restored', 'A'),
        ]
        for name, route, expected_state, expected_hit in phases:
            refuse_a.set() if expected_hit == 'refused' else refuse_a.clear()
            before = counts.copy()
            phase = run_phase(binary, stage, profiles[route], ports.get(route), target, nonce, expected_state)
            exited = wait_for_runtime_exit(runtime)
            hits = {key: counts[key] - before[key] for key in counts}
            phase.update(phase=name, expectedState=expected_state, routeHits=hits, runtimeExited=exited)
            report['phases'].append(phase)
            expected_count = hits[expected_hit]
            if (phase['status'] != 'PASS' or not phase['runtimeExited']
                    or expected_count < 1 or sum(hits.values()) != expected_count
                    or (expected_hit != 'refused' and expected_count != 1)):
                report['status'] = 'FAIL'
                save()
                return 1
    report['status'] = 'PASS'
    save()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
