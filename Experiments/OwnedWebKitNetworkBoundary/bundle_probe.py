#!/usr/bin/env python3
"""One headed baseline for a newly relinked, hardened standalone QA bundle.

No DYLD injection, persistent stores, Keychain, Internet endpoints or manager.
This validates changed packaging, not network confinement or release readiness.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import queue
import subprocess
import threading
import uuid

import probe


def environment_for_bundle(environment, app, fixed_framework_path):
    clean = {key: value for key, value in environment.items()
             if not key.startswith(('DYLD_', '__XPC_DYLD_'))}
    clean.pop('WEBKIT_UNSET_DYLD_FRAMEWORK_PATH', None)
    if fixed_framework_path:
        path = str(app / 'Contents/Frameworks')
        for key in ('DYLD_FRAMEWORK_PATH', 'DYLD_LIBRARY_PATH',
                    '__XPC_DYLD_FRAMEWORK_PATH', '__XPC_DYLD_LIBRARY_PATH'):
            clean[key] = path
        clean['WEBKIT_UNSET_DYLD_FRAMEWORK_PATH'] = 'YES'
    return clean


class BundleHost(probe.Host):
    def __init__(self, app, settings, log, fixed_framework_path=False):
        self.log = log.open('wb')
        environment = environment_for_bundle(os.environ, app, fixed_framework_path)
        self.process = subprocess.Popen([str(app / 'Contents/MacOS/Host')], env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.events = queue.Queue()
        self.reader = threading.Thread(target=self.read, daemon=True); self.reader.start()
        self.send(dict(settings, framework=str(app / 'Contents/Frameworks/WebKit.framework')))


def run(work, diagnose=False, fixed_framework_path=False):
    stem = 'standalone-diagnostic' if diagnose else 'standalone-native'
    result_path = work / (stem + '.json')
    if result_path.exists():
        raise RuntimeError('Preserve previous native result;diagnose before changed-input retry')
    app = work / 'NeAntik WebKit Bundle QA.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'app.neantik.webkit-bundle-qa':
        raise RuntimeError('Unexpected app identity')
    team = 'anchor apple generic and certificate leaf[subject.OU] = "H6VGU2M6JD"'
    # --deep propagates the requirement to nested code, whose identifiers are
    # intentionally distinct from the host. Bind team recursively, host ID once.
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep', '-R=' + team,
                    str(app)], check=True, capture_output=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict',
                    '-R=' + team + ' and identifier "app.neantik.webkit-bundle-qa"', str(app)],
                   check=True, capture_output=True)
    readiness = subprocess.run(['python3', '-B', str(probe.REPO / 'scripts/native-qa-readiness.py'), '--check'], capture_output=True, text=True)
    (work / (stem + '-admission.json')).write_text(readiness.stdout)
    if readiness.returncode:
        print(json.dumps({'status': 'native-deferred', 'readinessExit': readiness.returncode})); return
    marker = 'owned-' + uuid.uuid4().hex
    username, password = 'owned-fixture', uuid.uuid4().hex
    authority = 'owned-' + uuid.uuid4().hex + '.invalid:49151'
    origin = relay = None
    hosts = []
    result = {'status': 'FAIL', 'scope': 'standalone packaging baseline only;upstream sandbox',
              'hostSHA256': probe.digest(app / 'Contents/MacOS/Host'),
              'harnessSHA256': probe.digest(Path(__file__)),
              'frameworkSearch': 'fixed-own-signed-bundle' if fixed_framework_path else 'rpath-only',
              'cases': [], 'cleanup': {}, 'notarized': False}
    try:
        origin = probe.Endpoint('127.0.0.1', marker)
        relay = probe.Endpoint('127.0.0.1', marker,
                               auth=b'Basic ' + base64.b64encode(f'{username}:{password}'.encode()),
                               allowed=(authority,))
        for role, endpoint, url, proxied in [
                ('direct-baseline', origin, f'http://127.0.0.1:{origin.port}/', False),
                ('proxy-baseline', relay, f'http://{authority}/', True)]:
            result['phase'] = role + ':launch'
            host = BundleHost(app, {'role': role, 'proxy': proxied, 'proxyPort': relay.port,
                                   'username': username, 'password': password, 'urls': [url], 'marker': marker},
                              work / (stem + '-' + role + '.stderr'), fixed_framework_path)
            hosts.append(host)
            result['ownedPID'] = host.process.pid
            result['phase'] = role + ':ready'
            ready = host.wait('ready')
            result['ready'] = ready
            if ready.get('visible') is not True or ready.get('ownFramework') is not True:
                raise RuntimeError('Headed owned framework is not ready')
            before = endpoint.snapshot()['responses']
            host.send({'case': role, 'url': url})
            result['phase'] = role + ':navigation'
            navigation = host.wait('navigation')
            success = navigation.get('success') is True and endpoint.snapshot()['responses'] == before + 1
            result['cases'].append({'case': role, 'pass': success, 'code': navigation.get('code')})
            if not success:
                raise RuntimeError('Standalone baseline navigation failed')
            if not host.stop():
                raise RuntimeError('Owned host did not close normally')
            hosts.pop()
        result['status'] = 'PASS'
    except Exception as error:
        result['failureType'] = type(error).__name__
        result['failure'] = str(error)
        if diagnose and hosts and hosts[-1].process.poll() is None:
            # A stack sample of only our still-live child; kept private. Never
            # attach to an app discovered by name or relax hardened runtime.
            sample = subprocess.run(['/usr/bin/sample', str(hosts[-1].process.pid), '1',
                                     '-file', str(work / (stem + '.sample.txt'))],
                                    capture_output=True, timeout=8)
            result['sampleExit'] = sample.returncode
    finally:
        result['cleanup']['hostsNormalExit'] = all([host.stop() for host in hosts])
        result['cleanup']['originDrained'] = origin.stop() if origin else True
        result['cleanup']['relayDrained'] = relay.stop() if relay else True
        if not all(result['cleanup'].values()):
            result['status'] = 'FAIL'
        result_path.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'status': result['status'], 'cases': result['cases'], 'cleanup': result['cleanup']}))
    if result['status'] != 'PASS': raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--diagnose', action='store_true')
    parser.add_argument('--fixed-framework-path', action='store_true')
    args = parser.parse_args()
    run(args.work, args.diagnose, args.fixed_framework_path)
