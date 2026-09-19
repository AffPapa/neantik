"""Bounded local startup probe; only a newly created synthetic profile."""
import json
import argparse
import hashlib
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Page(BaseHTTPRequestHandler):
    route_hits = 0
    def do_GET(self):
        if self.path == '/owned-download.txt':
            body = b'NeAntik synthetic download\n'
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="owned-download.txt"')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith('/route-synthetic'):
            Page.route_hits += 1
        worker = self.path.startswith('/sw.js')
        body = (b"self.addEventListener('install',e=>self.skipWaiting());" if worker else b'<title>Owned storage probe</title>')
        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript' if worker else 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass

STORAGE_SCRIPT = r'''
const token = arguments[0], done = arguments[arguments.length - 1];
(async () => {
 const db = await new Promise((resolve,reject) => {
   const r = indexedDB.open('owned-probe',1);
   r.onupgradeneeded = () => r.result.createObjectStore('values');
   r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error);
 });
 if (token) {
   document.cookie = 'owned_probe='+token+'; Path=/; Max-Age=3600; SameSite=Lax';
   localStorage.setItem('owned_probe',token);
   await new Promise((resolve,reject) => {
     const tx=db.transaction('values','readwrite');
     tx.objectStore('values').put(token,'key');
     tx.oncomplete=resolve; tx.onerror=()=>reject(tx.error);
   });
   const cache=await caches.open('owned-probe');
   await cache.put('/owned-cache-key',new Response(token));
   await navigator.serviceWorker.register('/sw.js?token='+token);
   await navigator.serviceWorker.ready;
 }
 const indexed = await new Promise((resolve,reject) => {
   const r=db.transaction('values').objectStore('values').get('key');
   r.onsuccess=()=>resolve(r.result||''); r.onerror=()=>reject(r.error);
 });
 db.close();
 const cached=await caches.match('/owned-cache-key');
 const workers=await navigator.serviceWorker.getRegistrations();
 const sw=workers[0] && (workers[0].active || workers[0].waiting || workers[0].installing);
 done({cookie:document.cookie.split('; ').find(x=>x.startsWith('owned_probe='))?.split('=')[1]||'',
       local:localStorage.getItem('owned_probe')||'', indexed,
       cache:cached?await cached.text():'', worker:sw?new URL(sw.scriptURL).searchParams.get('token'):''});
})().catch(e=>done({error:String(e)}));
'''

COMPATIBILITY_SCRIPT = r'''
const done = arguments[arguments.length - 1];
(async () => {
 const checks = {};
 checks.secureContext = isSecureContext;
 checks.permissionsQuery = ['granted','denied','prompt'].includes(
   (await navigator.permissions.query({name:'geolocation'})).state);
 checks.mediaDevicesAPI = typeof navigator.mediaDevices?.getUserMedia === 'function';
 const canvas = document.createElement('canvas'); canvas.width=16; canvas.height=16;
 canvas.getContext('2d').fillRect(0,0,16,16);
 const stream = canvas.captureStream(1);
 checks.syntheticVideoTrack = stream.getVideoTracks().length === 1;
 stream.getTracks().forEach(t=>t.stop());
 checks.syntheticVideoStopped = stream.getTracks().every(t=>t.readyState==='ended');
 const audio = new OfflineAudioContext(1,128,44100);
 const oscillator=audio.createOscillator(); oscillator.connect(audio.destination); oscillator.start();
 const rendered=await audio.startRendering();
 checks.offlineAudio = rendered.length===128 && rendered.numberOfChannels===1;
 checks.worker = await new Promise((resolve,reject)=>{
   const url=URL.createObjectURL(new Blob(['onmessage=e=>postMessage(e.data+1)'],{type:'text/javascript'}));
   const worker=new Worker(url);
   const timeout=setTimeout(()=>{worker.terminate();URL.revokeObjectURL(url);reject(Error('worker timeout'));},5000);
   worker.onmessage=e=>{clearTimeout(timeout);worker.terminate();URL.revokeObjectURL(url);resolve(e.data===42);};
   worker.postMessage(41);
 });
 checks.iframe = await new Promise((resolve,reject)=>{
   const frame=document.createElement('iframe');
   const timeout=setTimeout(()=>{frame.remove();reject(Error('iframe timeout'));},5000);
   frame.onload=()=>{clearTimeout(timeout);const ok=frame.contentDocument.body.textContent==='synthetic';frame.remove();resolve(ok);};
   frame.srcdoc='<body>synthetic</body>';document.body.append(frame);
 });
 done(checks);
})().catch(e=>done({error:String(e)}));
'''

parser = argparse.ArgumentParser()
parser.add_argument('--runtime-app', type=Path, required=True)
parser.add_argument('--headed', action='store_true')
parser.add_argument('--smoke-only', action='store_true')
parser.add_argument('--driver', type=Path, required=True)
parser.add_argument('--expected-version', default='153.0.8010.36')
options = parser.parse_args()
RUNTIME = options.runtime_app / 'Contents/MacOS/NeAntik Browser'
MODE_ARGS = [] if options.headed else ['--headless=new']
EXECUTION_MODE = 'webdriver-headed-multiprocess' if options.headed else 'webdriver-headless-multiprocess'
def file_hash(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
FRAMEWORK = options.runtime_app / 'Contents/Frameworks/NeAntik Browser Framework.framework/NeAntik Browser Framework'
def runtime_identity():
    return {'mainSHA256':file_hash(RUNTIME), 'frameworkSHA256':file_hash(FRAMEWORK),
            'driverSHA256':file_hash(options.driver), 'expectedVersion':options.expected_version}
RUNTIME_IDENTITY = runtime_identity()
profile = Path(tempfile.mkdtemp(prefix='neantik-webdriver-probe-', dir='/private/tmp'))
with socket.socket() as reservation:
    reservation.bind(('127.0.0.1', 0))
    port = reservation.getsockname()[1]
base = f'http://127.0.0.1:{port}'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={'Content-Type': 'application/json'})
    with opener.open(req, timeout=20) as response:
        result = json.load(response)
    if method == 'POST' and path == '/session':
        value = result.get('value', {})
        actual = value.get('capabilities', {}).get('browserVersion')
        if actual != options.expected_version:
            mismatched_session = value.get('sessionId')
            if isinstance(mismatched_session, str):
                request('DELETE', '/session/' + mismatched_session)
            raise RuntimeError('Measured browser version does not match requested runtime')
    return result


with (profile / 'driver.log').open('w') as log:
    driver = subprocess.Popen([str(options.driver), f'--port={port}', '--allowed-ips=127.0.0.1'], stdout=log, stderr=log)
    session = None
    try:
        for _ in range(50):
            if driver.poll() is not None:
                raise RuntimeError('ChromeDriver exited before readiness')
            try:
                request('GET', '/status')
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError('ChromeDriver readiness timeout')
        result = request('POST', '/session', {'capabilities': {'alwaysMatch': {
            'browserName': 'chrome', 'goog:chromeOptions': {
                'binary': str(RUNTIME),
                'args': [*MODE_ARGS, '--no-first-run', '--disable-background-networking',
                         '--user-data-dir=' + str(profile / 'profile')]
            }}}})
        session = result['value']['sessionId']
        print('session-created', flush=True)
        request('POST', f'/session/{session}/url', {'url': 'data:text/html,<title>Owned probe</title><p>synthetic</p>'})
        print('title', request('GET', f'/session/{session}/title')['value'], flush=True)
        print('quit', request('DELETE', f'/session/{session}')['value'], flush=True)
        session = None
        if options.smoke_only:
            raise SystemExit(0)
        server = ThreadingHTTPServer(('127.0.0.1',0), Page)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        captures = {}
        try:
            downloads = profile / 'downloads'
            downloads.mkdir()
            extension = Path(__file__).resolve().parent / 'fixtures/owned-runtime-extension'
            opened = request('POST', '/session', {'capabilities': {'alwaysMatch': {
                'browserName': 'chrome', 'goog:chromeOptions': {
                    'binary': str(RUNTIME), 'prefs': {
                        'download.default_directory': str(downloads),
                        'download.prompt_for_download': False},
                    'args': [*MODE_ARGS, '--no-first-run',
                        '--disable-background-networking', '--no-proxy-server',
                        '--load-extension=' + str(extension),
                        '--user-data-dir=' + str(profile / 'compatibility')]}}}})
            session = opened['value']['sessionId']
            request('POST', f'/session/{session}/url', {'url': f'http://127.0.0.1:{server.server_port}/'})
            compatibility = request('POST', f'/session/{session}/execute/async', {
                'script': COMPATIBILITY_SCRIPT, 'args': []})['value']
            required_checks = {'secureContext', 'permissionsQuery', 'mediaDevicesAPI',
                               'syntheticVideoTrack', 'syntheticVideoStopped',
                               'offlineAudio', 'worker', 'iframe'}
            if set(compatibility) != required_checks or any(value is not True for value in compatibility.values()):
                raise RuntimeError('Owned compatibility probe failed: ' + json.dumps(compatibility))
            extension_loaded = request('POST', f'/session/{session}/execute/sync', {
                'script': 'return document.documentElement.dataset.neantikOwnedExtension === "loaded";',
                'args': []})['value']
            if extension_loaded is not True:
                raise RuntimeError('Owned Manifest V3 content script did not execute')
            compatibility['manifestV3ContentScript'] = True
            request('POST', f'/session/{session}/execute/sync', {
                'script': 'const a=document.createElement("a");a.href="/owned-download.txt";document.body.append(a);a.click();',
                'args': []})
            downloaded = downloads / 'owned-download.txt'
            for _ in range(100):
                if downloaded.is_file() and not downloaded.is_symlink():
                    break
                time.sleep(0.1)
            if not downloaded.is_file() or downloaded.is_symlink() or downloaded.read_bytes() != b'NeAntik synthetic download\n':
                raise RuntimeError('Owned download missing or bytes differ')
            compatibility['downloadExactBytes'] = True
            request('DELETE', f'/session/{session}')
            session = None
            (profile / 'compatibility-results.json').write_text(json.dumps({
                'scope': 'loopback synthetic media, permissions-query, exact download and own unpacked MV3 content script; no hardware access',
                'mode': EXECUTION_MODE, 'runtime': RUNTIME_IDENTITY, 'checks': compatibility}, indent=2))
            print('compatibility-pass', len(compatibility), flush=True)
            for label, place, token, expected in [
                ('aSet','A','synthetic-A','synthetic-A'),
                ('aRead','A','','synthetic-A'),
                ('bEmpty','B','',''),
                ('bSet','B','synthetic-B','synthetic-B'),
                ('aUnchanged','A','','synthetic-A'),
                ('bRead','B','','synthetic-B')]:
                opened = request('POST','/session',{'capabilities':{'alwaysMatch':{
                    'browserName':'chrome','goog:chromeOptions':{
                        'binary':str(RUNTIME),
                        'args':[*MODE_ARGS,'--no-first-run','--disable-background-networking',
                                '--user-data-dir='+str(profile/place)]}}}})
                session=opened['value']['sessionId']
                request('POST',f'/session/{session}/url',{'url':f'http://127.0.0.1:{server.server_port}/'})
                value=request('POST',f'/session/{session}/execute/async',{'script':STORAGE_SCRIPT,'args':[token]})['value']
                captures[label]=value
                if value != {k:expected for k in ('cookie','local','indexed','cache','worker')}:
                    raise RuntimeError('Synthetic storage expectation failed: ' + label)
                request('POST',f'/session/{session}/refresh', {})
                reloaded=request('POST',f'/session/{session}/execute/async',{'script':STORAGE_SCRIPT,'args':['']})['value']
                if reloaded != value:
                    raise RuntimeError('Synthetic storage changed after reload: ' + label)
                captures[label + 'Reload'] = reloaded
                request('DELETE',f'/session/{session}')
                session=None
                print('storage-pass',label,flush=True)
            (profile/'storage-results.json').write_text(json.dumps({'mode':EXECUTION_MODE,'runtime':RUNTIME_IDENTITY,'captures':captures},indent=2))
            # Hold a non-listening local TCP port so no third party can become
            # the intended dead proxy during the fail-closed experiment.
            with socket.socket() as dead_proxy:
                dead_proxy.bind(('127.0.0.1',0))
                proxy_port=dead_proxy.getsockname()[1]
                observations={}
                for mode,flags in [
                    ('direct',['--no-proxy-server']),
                    ('dead-proxy',[f'--proxy-server=http://127.0.0.1:{proxy_port}',
                                   '--proxy-bypass-list=<-loopback>',
                                   '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
                                   '--disable-quic','--webrtc-ip-handling-policy=disable_non_proxied_udp'])]:
                    opened=request('POST','/session',{'capabilities':{'alwaysMatch':{
                        'browserName':'chrome','goog:chromeOptions':{
                            'binary':str(RUNTIME),
                            'args':[*MODE_ARGS,'--no-first-run','--disable-background-networking',
                                    '--user-data-dir='+str(profile/mode),*flags]}}}})
                    session=opened['value']['sessionId']
                    before=Page.route_hits
                    proxy_error=False
                    try:
                        request('POST',f'/session/{session}/url',{'url':f'http://127.0.0.1:{server.server_port}/route-synthetic'})
                    except urllib.error.HTTPError as error:
                        details=json.load(error)
                        proxy_error='ERR_PROXY_CONNECTION_FAILED' in details.get('value',{}).get('message','')
                        if not proxy_error:
                            raise
                    request('DELETE',f'/session/{session}')
                    session=None
                    hits=Page.route_hits-before
                    observations[mode]={'originRequests':hits,'proxyConnectionFailed':proxy_error}
                    passed = (hits>=1 and not proxy_error) if mode=='direct' else (hits==0 and proxy_error)
                    if not passed:
                        raise RuntimeError('Measured loopback route expectation failed: ' + mode)
                    print('route-pass',mode,flush=True)
                if RUNTIME_IDENTITY != runtime_identity():
                    raise RuntimeError('Runtime bytes changed during probe')
                (profile/'route-results.json').write_text(json.dumps({'scope':'loopback HTTP unavailable-proxy only','mode':EXECUTION_MODE,'runtime':RUNTIME_IDENTITY,'observations':observations},indent=2))
        finally:
            server.shutdown()
            server.server_close()
    finally:
        if session:
            try:
                request('DELETE', f'/session/{session}')
            except OSError:
                print('quit-failed', flush=True)
        driver.terminate()
        try:
            driver.wait(timeout=5)
        except subprocess.TimeoutExpired:
            driver.kill()
            driver.wait()
        print('retained synthetic evidence', profile, flush=True)
