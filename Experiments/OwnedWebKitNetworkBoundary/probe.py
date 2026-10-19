#!/usr/bin/env python3
"""Research only: owned WebKit runtime + kernel sandbox versus an owned origin.

prepare compiles a tiny host once. run never builds Chromium or the manager,
changes system network settings, installs extensions, or opens a real profile.
"""
import argparse
import base64
import ctypes
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import queue
import re
import socket
import subprocess
import threading
import time
import uuid

REPO = Path(__file__).resolve().parents[2]
IDENTITY = '474F7C78F33EE324C24F6F5AE0443EB713E85E60'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def sandbox_overlay(port):
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('Invalid owned relay port')
    # Seatbelt's network address grammar accepts localhost, not literal IPs.
    return ('\n; NeAntik owned QA: only the own relay can carry IP traffic.\n'
            '; Preserve the original profile\'s routing metadata and local log service.\n'
            '(deny network-outbound (require-not (require-any\n'
            f'    (remote tcp "localhost:{port}")\n'
            '    (control-name "com.apple.netsrc")\n'
            '    (literal "/private/var/run/syslog"))))\n')


def compile_overlay(overlay):
    """Compile only. This never applies a sandbox to the runner or another app."""
    library = ctypes.CDLL('/usr/lib/libsandbox.1.dylib')
    library.sandbox_compile_string.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    library.sandbox_compile_string.restype = ctypes.c_void_p
    library.sandbox_free_profile.argtypes = [ctypes.c_void_p]
    library.sandbox_free_error.argtypes = [ctypes.c_void_p]
    error = ctypes.c_void_p()
    profile = library.sandbox_compile_string(('(version 1)\n(allow default)\n' + overlay).encode(), None, ctypes.byref(error))
    if not profile:
        message = ctypes.string_at(error).decode() if error else 'Unknown sandbox compilation failure'
        if error: library.sandbox_free_error(error)
        raise ValueError(message)
    library.sandbox_free_profile(profile)


def normalize_framework(work):
    """SDK text stubs are build inputs, not signable runtime components."""
    framework = work / 'Release-A/WebKit.framework'
    stub = framework / 'Versions/A/WebKit.tbd'
    link = framework / 'WebKit.tbd'
    if not stub.is_file() or stub.is_symlink() or not link.is_symlink() or str(link.readlink()) != 'Versions/Current/WebKit.tbd':
        raise RuntimeError('Unexpected development stub layout')
    backup = work / 'development-files'; backup.mkdir()
    receipt = {'regularFileSHA256': digest(stub), 'symlinkTarget': str(link.readlink()),
               'purpose': 'preserve unused SDK stubs outside own runtime before signing;original archive unchanged'}
    stub.rename(backup / 'WebKit.tbd'); link.rename(backup / 'WebKit.tbd.link')
    write_json(backup / 'receipt.json', receipt)


def prepare(archive, work):
    if work.exists():
        raise RuntimeError('Preparation root exists; do not replace or rebuild it')
    work.mkdir(parents=True)
    release = archive / 'unpacked/Release'
    if not (release / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb').is_file():
        raise RuntimeError('Inspected WebKit archive required')
    developer = subprocess.check_output([str(REPO / 'scripts/resolve-compatible-developer-dir.sh')], text=True).strip()
    env = dict(os.environ, DEVELOPER_DIR=developer)
    host = work / 'host'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-fmodules', '-arch', 'arm64',
                    '-mmacosx-version-min=26.5', '-framework', 'AppKit', '-framework', 'WebKit',
                    '-framework', 'Network', str(Path(__file__).with_name('Host.m')),
                    '-o', str(host)], env=env, check=True)
    apps = []
    for role in ('A', 'B'):
        app = work / f'Owned WebKit {role}.app'
        macos = app / 'Contents/MacOS'; macos.mkdir(parents=True)
        subprocess.run(['/bin/cp', str(host), str(macos / 'Host')], check=True)
        info = {'CFBundleExecutable': 'Host', 'CFBundleIdentifier': f'app.neantik.webkit-boundary-qa.{role.lower()}',
                'CFBundleName': f'NeAntik Owned WebKit {role}', 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1', 'LSMinimumSystemVersion': '26.5', 'NSHighResolutionCapable': True,
                'NSAppTransportSecurity': {'NSAllowsArbitraryLoadsInWebContent': True}}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        # QA host is intentionally not a hardened/notarized release candidate.
        # No new entitlement or certificate is introduced.
        subprocess.run(['/usr/bin/codesign', '--sign', IDENTITY, '--timestamp=none', str(app)], check=True)
        apps.append(str(app))
    own_release = work / 'Release-A'; own_release.mkdir()
    for child in release.iterdir():
        target = own_release / child.name
        # The relocated upstream sandbox admits this directory, not external
        # symlink targets. In particular WebCore's localized bundle must remain
        # readable after the helper enters its sandbox.
        subprocess.run(['/bin/cp', '-cR', str(child), str(target)], check=True)
    normalize_framework(work)
    write_json(work / 'prepared.json', {'schemaVersion': 1, 'release': str(release), 'ownRelease': str(own_release),
               'hostSHA256': digest(host), 'sourceSHA256': digest(Path(__file__).with_name('Host.m')),
               'archiveReceipt': str(archive / 'extraction.json'), 'apps': apps,
               'signedAppSHA256': {app: digest(Path(app) / 'Contents/MacOS/Host') for app in apps},
               'nativeLaunched': False})
    print(json.dumps({'status': 'prepared-only', 'hostSHA256': digest(host), 'appCount': len(apps)}))


def read_header(connection):
    value = b''
    while b'\r\n\r\n' not in value:
        chunk = connection.recv(4096)
        if not chunk:
            raise EOFError()
        value += chunk
        if len(value) > 16384:
            raise ValueError('Header budget')
    return value


class Endpoint:
    def __init__(self, host, marker, auth=None, allowed=(), path='/'):
        self.socket = socket.socket(); self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((host, 0)); self.socket.listen(16); self.socket.settimeout(.1)
        self.port = self.socket.getsockname()[1]
        self.marker, self.auth, self.allowed, self.path = marker, auth, allowed, path
        self.stopping = threading.Event(); self.refusing = False
        self.counts = {'accepted': 0, 'authenticated': 0, 'responses': 0, 'refused': 0}
        self.lock = threading.Lock(); self.active = set(); self.workers = []
        self.thread = threading.Thread(target=self.serve, daemon=True); self.thread.start()

    def increment(self, key):
        with self.lock:
            self.counts[key] += 1

    def snapshot(self):
        with self.lock:
            return dict(self.counts)

    def serve(self):
        while not self.stopping.is_set():
            try:
                client, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self.lock:
                if self.stopping.is_set():
                    client.close(); break
                self.active.add(client)
                self.counts['accepted'] += 1
                worker = threading.Thread(target=self.handle, args=(client,), daemon=True)
                self.workers.append(worker); worker.start()

    def handle(self, client):
        try:
            client.settimeout(6)
            if self.refusing:
                self.increment('refused'); return
            header = read_header(client)
            if self.auth:
                first = header.split(b'\r\n', 1)[0].decode('ascii')
                if first not in [f'CONNECT {authority} HTTP/1.1' for authority in self.allowed]:
                    self.increment('refused'); return
                fields = {line.split(b':', 1)[0].lower(): line.split(b':', 1)[1].strip()
                          for line in header.split(b'\r\n')[1:] if b':' in line}
                if fields.get(b'proxy-authorization') != self.auth:
                    client.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="Owned QA"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                    return
                self.increment('authenticated')
                client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
                header = read_header(client)
            if header.split(b'\r\n', 1)[0] != f'GET {self.path} HTTP/1.1'.encode():
                self.increment('refused'); return
            body = ('<!doctype html><body>' + self.marker + '</body>').encode()
            client.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
            self.increment('responses')
        except (OSError, EOFError, ValueError, UnicodeError):
            self.increment('refused')
        finally:
            with self.lock:
                self.active.discard(client)
            client.close()

    def stop(self):
        self.stopping.set(); self.socket.close()
        with self.lock:
            active = list(self.active)
        for connection in active:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        self.thread.join(2)
        for worker in self.workers:
            worker.join(2)
        return not self.thread.is_alive() and not any(w.is_alive() for w in self.workers)


class Host:
    def __init__(self, app, release, settings, log):
        self.log = log.open('wb')
        env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(release), DYLD_LIBRARY_PATH=str(release))
        self.process = subprocess.Popen([str(Path(app) / 'Contents/MacOS/Host')], env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.events = queue.Queue()
        self.reader = threading.Thread(target=self.read, daemon=True); self.reader.start()
        self.send(dict(settings, framework=str(release / 'WebKit.framework')))

    def read(self):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except (ValueError, UnicodeError):
                self.events.put({'event': 'invalid-output'})

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n'); self.process.stdin.flush()

    def wait(self, event, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.events.get(timeout=.1)
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError('Owned host exited before event')
                continue
            if value.get('event') == event:
                return value
            if value.get('event') in ('refused', 'invalid-output'):
                raise RuntimeError('Owned host refused configuration')
        raise TimeoutError('Owned host event timed out')

    def stop(self):
        if self.process.poll() is None:
            try:
                self.send({'action': 'quit'}); self.process.wait(timeout=8)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate(); self.process.wait(timeout=5)
        self.reader.join(2); self.process.stdin.close(); self.process.stdout.close(); self.log.close()
        return self.process.returncode == 0


def diagnose_proxy(work, own_signed=False):
    """Separate an archive/proxy API problem from the new sandbox policy."""
    stem = 'own-signed-proxy-control' if own_signed else 'unrestricted-proxy-control'
    report_path = work / (stem + '.json')
    if report_path.exists():
        raise RuntimeError('Proxy control already recorded;do not repeat unchanged')
    prepared = json.loads((work / 'prepared.json').read_text())
    app = prepared['apps'][0 if own_signed else 1]
    role = 'A' if own_signed else 'B'
    if app != str(work / f'Owned WebKit {role}.app') or digest(Path(app) / 'Contents/MacOS/Host') != prepared['signedAppSHA256'][app]:
        raise RuntimeError('Own signed app changed')
    readiness = subprocess.run(['python3', '-B', str(REPO / 'scripts/native-qa-readiness.py'), '--check'], capture_output=True, text=True)
    (work / (stem + '-admission.json')).write_text(readiness.stdout)
    if readiness.returncode:
        print(json.dumps({'status': 'native-deferred', 'readinessExit': readiness.returncode})); return
    marker = 'owned-' + uuid.uuid4().hex
    authority = 'owned-' + uuid.uuid4().hex + '.invalid:49151'
    username, password = 'owned-fixture', uuid.uuid4().hex
    endpoint = Endpoint('127.0.0.1', marker, auth=b'Basic ' + base64.b64encode(f'{username}:{password}'.encode()),
                        allowed=(authority,))
    host = None
    result = {'scope': 'unrestricted owned archive proxy API positive control only',
              'harnessSHA256': digest(Path(__file__)), 'sourceSHA256': prepared['sourceSHA256']}
    try:
        runtime = Path(prepared['ownRelease'] if own_signed else prepared['release'])
        if own_signed:
            original = Path(prepared['release']) / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
            policy = runtime / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
            policy.write_bytes(original.read_bytes())
            subprocess.run(['/usr/bin/codesign','--force','--sign',IDENTITY,'--timestamp=none',str(runtime/'WebKit.framework')],check=True,capture_output=True)
            result['policy'] = 'unmodified upstream;own normalized and Developer ID signed framework'
        url = 'http://' + authority + '/'
        host = Host(app, runtime, {'role': 'proxy-control', 'proxy': True,
                    'proxyPort': endpoint.port, 'username': username, 'password': password,
                    'urls': [url], 'marker': marker}, work / (stem + '.stderr'))
        result['ready'] = host.wait('ready')
        host.send({'action': 'navigate', 'case': 'unrestricted-proxy-positive', 'url': url})
        result['navigation'] = host.wait('navigation')
    except Exception as error:
        result['errorType'] = type(error).__name__
    finally:
        result['hostNormalExit'] = host.stop() if host else True
        result['endpointDrained'] = endpoint.stop()
        result['counts'] = endpoint.snapshot()
        result['status'] = 'PASS' if result.get('navigation', {}).get('success') is True and result['counts']['authenticated'] > 0 and result['counts']['responses'] > 0 and result['hostNormalExit'] and result['endpointDrained'] else 'FAIL'
        write_json(report_path, result); print(json.dumps(result, indent=2))


def diagnose_bypass(work):
    """Intentional broken control: same configured runtime, no deny overlay."""
    report = work / 'unconfined-bypass-control.json'
    if report.exists():
        raise RuntimeError('Negative control already recorded;do not repeat unchanged')
    prepared = json.loads((work / 'prepared.json').read_text())
    if json.loads((work / 'native-result.json').read_text())['status'] != 'PASS':
        raise RuntimeError('Freeze the protected result first')
    runtime = work / 'Release-C'
    if runtime.exists():
        raise RuntimeError('Control runtime exists;inspect before reuse')
    subprocess.run(['/bin/cp','-cR',prepared['ownRelease'],str(runtime)],check=True)
    policy = runtime / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
    original = Path(prepared['release']) / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
    policy.write_bytes(original.read_bytes())
    subprocess.run(['/usr/bin/codesign','--force','--sign',IDENTITY,'--timestamp=none',str(runtime/'WebKit.framework')],check=True,capture_output=True)
    readiness = subprocess.run(['python3','-B',str(REPO/'scripts/native-qa-readiness.py'),'--check'],capture_output=True,text=True)
    (work/'bypass-control-admission.json').write_text(readiness.stdout)
    if readiness.returncode:
        print(json.dumps({'status':'native-deferred','readinessExit':readiness.returncode})); return
    addresses = re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)\b', subprocess.check_output(['/sbin/ifconfig'],text=True))
    address = next((a for a in addresses if ipaddress.ip_address(a).is_private and not ipaddress.ip_address(a).is_loopback),None)
    if address is None: raise RuntimeError('Own private IPv4 required')
    nonce = uuid.uuid4().hex; marker = 'owned-' + nonce
    origin = Endpoint(address,marker,path='/' + nonce); proxy = None; host = None
    result = {'scope':'intentional unconfined configured-proxy negative control;not a safe product mode',
              'harnessSHA256':digest(Path(__file__)),'policySHA256':digest(policy),'controls':[]}
    try:
        username,password = 'owned-fixture',uuid.uuid4().hex
        authorities = (f'owned-{nonce}.invalid:{origin.port}',f'{address}:{origin.port}')
        proxy = Endpoint('127.0.0.1',marker,auth=b'Basic '+base64.b64encode(f'{username}:{password}'.encode()),allowed=authorities,path='/' + nonce)
        urls = ['http://' + a + '/' + nonce for a in authorities]
        host = Host(prepared['apps'][1],runtime,{'role':'unconfined-negative','proxy':True,
                    'proxyPort':proxy.port,'username':username,'password':password,'urls':urls,'marker':marker},work/'bypass-control.stderr')
        host.wait('ready')
        for label,url in zip(('named-authenticated-positive','private-direct-bypass-negative'),urls):
            before_o,before_p = origin.snapshot()['responses'],proxy.snapshot()['responses']
            host.send({'action':'navigate','case':label,'url':url}); event = host.wait('navigation')
            result['controls'].append({'case':label,'success':event['success'],
                'directResponses':origin.snapshot()['responses']-before_o,'relayResponses':proxy.snapshot()['responses']-before_p})
    except Exception as error:
        result['errorType'] = type(error).__name__
    finally:
        result['hostNormalExit'] = host.stop() if host else True
        result['proxyDrained'] = proxy.stop() if proxy else True; result['originDrained'] = origin.stop()
        expected = [{'case':'named-authenticated-positive','success':True,'directResponses':0,'relayResponses':1},
                    {'case':'private-direct-bypass-negative','success':True,'directResponses':1,'relayResponses':0}]
        result['status'] = 'PASS-control-catches-bypass' if result['controls']==expected and result['hostNormalExit'] and result['proxyDrained'] and result['originDrained'] else 'FAIL-control-incomplete'
        write_json(report,result);print(json.dumps(result,indent=2))


def run(work):
    prepared = json.loads((work / 'prepared.json').read_text())
    if digest(work / 'host') != prepared['hostSHA256'] or digest(Path(__file__).with_name('Host.m')) != prepared['sourceSHA256']:
        raise RuntimeError('Prepared host is stale; never silently rebuild')
    expected_apps = [str(work / f'Owned WebKit {role}.app') for role in ('A', 'B')]
    if prepared['apps'] != expected_apps or any(digest(Path(app) / 'Contents/MacOS/Host') != prepared.get('signedAppSHA256', {}).get(app) for app in expected_apps):
        raise RuntimeError('Owned app path or executable changed')
    readiness = subprocess.run(['python3', '-B', str(REPO / 'scripts/native-qa-readiness.py'), '--check'], capture_output=True, text=True)
    (work / 'admission.json').write_text(readiness.stdout)
    if readiness.returncode:
        print(json.dumps({'status': 'native-deferred', 'readinessExit': readiness.returncode})); return
    if (work / 'native-result.json').exists():
        raise RuntimeError('Native phase already has a result; diagnose before repeating')
    interfaces = subprocess.check_output(['/sbin/ifconfig'], text=True)
    candidates = re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)\b', interfaces)
    address = next((a for a in candidates if ipaddress.ip_address(a).is_private and not ipaddress.ip_address(a).is_loopback), None)
    if address is None:
        raise RuntimeError('Own reachable private IPv4 is required')
    nonce = uuid.uuid4().hex; marker = 'owned-' + nonce
    origin = Endpoint(address, marker, path='/' + nonce); proxy = None; hosts = []
    result = {'schemaVersion': 1, 'scope': 'research-owned-WebKit HTTP named/privateIPv4 only;not production qualification',
              'controls': [], 'failures': [], 'cleanup': {}, 'source': prepared['sourceSHA256'],
              'harnessSHA256': digest(Path(__file__))}
    phase = 'prepare-policy'
    try:
        username, password = 'owned-fixture', uuid.uuid4().hex
        authorities = (f'owned-{nonce}.invalid:{origin.port}', f'{address}:{origin.port}')
        auth = b'Basic ' + base64.b64encode(f'{username}:{password}'.encode())
        proxy = Endpoint('127.0.0.1', marker, auth=auth, allowed=authorities, path='/' + nonce)
        own_release = Path(prepared['ownRelease']); release = Path(prepared['release'])
        policy = own_release / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
        original = (release / 'WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb').read_text()
        overlay = sandbox_overlay(proxy.port)
        compile_overlay(overlay)
        policy.write_text(original + overlay)
        result['policySHA256'] = digest(policy)
        phase = 'sign-own-framework'
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', IDENTITY, '--timestamp=none', str(own_release / 'WebKit.framework')], check=True, capture_output=True)
        urls = [f'http://{authority}/{nonce}' for authority in authorities]
        for role, runtime, app in zip(('A','B'), (own_release, release), prepared['apps']):
            phase = 'start-host-' + role
            h = Host(app, runtime, {'role': role, 'proxy': role == 'A', 'proxyPort': proxy.port,
                     'username': username, 'password': password, 'urls': urls, 'marker': marker}, work / f'host-{role}.stderr')
            hosts.append(h); ready = h.wait('ready')
            if ready.get('visible') is not True or ready.get('ownFramework') is not True:
                raise RuntimeError('Visible own-runtime control failed')
        a, b = hosts
        phase = 'browser-controls'
        def navigation(host, label, url, expected, through_proxy=False):
            before_direct, before_proxy = origin.snapshot()['responses'], proxy.snapshot()['responses']
            host.send({'action': 'navigate', 'case': label, 'url': url})
            event = host.wait('navigation')
            time.sleep(.1)
            direct = origin.snapshot()['responses'] - before_direct
            relayed = proxy.snapshot()['responses'] - before_proxy
            passed = event.get('success') is expected and (direct == 0 if host is a else direct > 0)
            if through_proxy:
                passed = passed and relayed > 0
            result['controls'].append({'case': label, 'success': event.get('success'), 'code': event.get('code'),
                                       'directResponses': direct, 'relayResponses': relayed, 'passed': passed})
            if not passed:
                result['failures'].append(label)
            return passed
        if not navigation(b, 'independent-direct-ready', urls[1], True):
            raise RuntimeError('Independent Direct positive failed')
        if not navigation(a, 'named-relay-ready', urls[0], True, through_proxy=True):
            raise RuntimeError('Own relay positive failed')
        navigation(a, 'private-direct-denied', urls[1], False)
        proxy.refusing = True
        navigation(a, 'named-relay-refused', urls[0], False)
        navigation(a, 'private-while-refused', urls[1], False)
        navigation(b, 'independent-direct-during-refusal', urls[1], True)
        proxy.refusing = False
        navigation(a, 'named-relay-recovered', urls[0], True, through_proxy=True)
    except Exception as error:
        result['setupErrorType'] = type(error).__name__
        result['failedPhase'] = phase
        if isinstance(error, subprocess.CalledProcessError):
            (work / 'setup-error.stderr').write_bytes(error.stderr or b'')
        result['failures'].append('incomplete-owned-runtime-stage')
    finally:
        own_executables = [str(p) for p in Path(prepared['ownRelease']).glob('com.apple.WebKit.*.xpc/Contents/MacOS/*') if p.is_file()]
        if own_executables:
            own_state = subprocess.run(['/usr/sbin/lsof', '-t', *own_executables], capture_output=True, text=True)
            result['ownRuntimePIDsBeforeCleanup'] = sorted({int(p) for p in own_state.stdout.split() if p.isdecimal()})
        result['cleanup']['hostsNormalExit'] = [h.stop() for h in reversed(hosts)]
        result['cleanup']['proxyDrained'] = proxy.stop() if proxy else True
        result['cleanup']['originDrained'] = origin.stop()
        result['fixtureCounts'] = {'proxy': proxy.snapshot() if proxy else {}, 'origin': origin.snapshot()}
        # Query only executable files from our two private runtime roots.
        # No global process arguments, other WebKit instances, or signals.
        executable_paths = [str(p) for key in ('release', 'ownRelease')
                            for p in Path(prepared[key]).glob('com.apple.WebKit.*.xpc/Contents/MacOS/*') if p.is_file()]
        helpers_gone = False
        deadline = time.monotonic() + 8
        while executable_paths and time.monotonic() < deadline:
            state = subprocess.run(['/usr/sbin/lsof', '-t', *executable_paths], capture_output=True, text=True)
            if state.returncode == 1 and not state.stdout.strip() and not state.stderr.strip():
                helpers_gone = True; break
            if state.returncode not in (0, 1):
                break
            time.sleep(.2)
        result['cleanup']['ownedHelpersAbsent'] = helpers_gone
        result['status'] = 'PASS' if not result['failures'] and len(result['controls']) == 7 and all(result['cleanup']['hostsNormalExit']) and result['cleanup']['proxyDrained'] and result['cleanup']['originDrained'] and helpers_gone else 'FAIL'
        write_json(work / 'native-result.json', result)
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('action', choices=['prepare','run','diagnose-proxy','diagnose-own-signed','diagnose-bypass'])
    parser.add_argument('--archive-root', type=Path); parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'prepare':
        if args.archive_root is None: parser.error('--archive-root required')
        prepare(args.archive_root.resolve(), args.work_dir.resolve())
    elif args.action == 'run':
        run(args.work_dir.resolve())
    elif args.action == 'diagnose-bypass':
        diagnose_bypass(args.work_dir.resolve())
    else:
        diagnose_proxy(args.work_dir.resolve(), own_signed=args.action == 'diagnose-own-signed')
