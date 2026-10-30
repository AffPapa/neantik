#!/usr/bin/env python3
"""Research: fixed loopback boundary on the standalone hardened WebKit bundle.

Eight HTTP controls include a deliberately unconfined configured-proxy control.
This is not a shipping broker, DNS/TLS/UDP qualification or manager integration.
"""
import argparse
import base64
import ipaddress
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time
import uuid

import probe
from assemble_layout import clone, validate_links
from bundle_probe import BundleHost

PORT = 45100
APP = 'NeAntik WebKit Bundle QA.app'
BASE_ID = 'app.neantik.webkit-bundle-qa'
RESTRICTED_ID = BASE_ID + '.restricted'


def prepare(baseline, work):
    if work.exists(): raise ValueError('Preserve previous assembly and results')
    previous = json.loads((baseline / 'standalone-diagnostic.json').read_text())
    if previous['status'] != 'PASS' or previous.get('frameworkSearch') != 'fixed-own-signed-bundle':
        raise ValueError('Matched standalone positive baseline required')
    original_app = baseline / APP
    validate_links(original_app)
    work.mkdir(parents=True)
    app = work / APP; clone(original_app, app)
    info_path = app / 'Contents/Info.plist'; info = plistlib.loads(info_path.read_bytes())
    if info['CFBundleIdentifier'] != BASE_ID: raise ValueError('Unexpected baseline identity')
    info['CFBundleIdentifier'] = RESTRICTED_ID
    info_path.write_bytes(plistlib.dumps(info))
    policy = app / 'Contents/Frameworks/WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
    original_sha = probe.digest(policy)
    overlay = probe.sandbox_overlay(PORT); probe.compile_overlay(overlay)
    policy.write_text(policy.read_text() + overlay)
    ent = work / 'host.entitlements.plist'
    ent.write_bytes(plistlib.dumps({'com.apple.security.cs.allow-dyld-environment-variables': True}))
    signed = []
    for target, entitlement in [(app / 'Contents/Frameworks/WebKit.framework', None), (app, ent)]:
        args = ['/usr/bin/codesign', '--force', '--sign', probe.IDENTITY,
                '--options', 'runtime', '--timestamp=none']
        if entitlement: args += ['--entitlements', str(entitlement)]
        output = subprocess.run(args + [str(target)], capture_output=True, text=True)
        signed.append({'target': target.name, 'exit': output.returncode})
        if output.returncode: raise RuntimeError(output.stderr)
    verify(app, RESTRICTED_ID)
    probe.write_json(work / 'prepared.json', {'status': 'prepared-only', 'baseline': str(baseline),
                     'fixedQAPort': PORT, 'policyInputSHA256': original_sha,
                     'policySHA256': probe.digest(policy), 'signing': signed,
                     'nativeLaunched': False, 'notarized': False,
                     'appExecutableSHA256': probe.digest(app / 'Contents/MacOS/Host')})
    print(json.dumps({'status': 'prepared-and-strict-verified', 'fixedQAPort': PORT}))


def verify(app, identifier):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != identifier: raise ValueError('Own app identity mismatch')
    team = 'anchor apple generic and certificate leaf[subject.OU] = "H6VGU2M6JD"'
    for extra in [('--deep', '-R=' + team), ('-R=' + team + ' and identifier "' + identifier + '"',)]:
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', *extra, str(app)],
                       check=True, capture_output=True)


def helper_paths(app):
    return [p for p in (app / 'Contents/Frameworks/WebKit.framework/Versions/A/XPCServices').glob(
        '*.xpc/Contents/MacOS/*') if p.is_file()]


def run(work):
    report = work / 'confined-native.json'
    if report.exists(): raise ValueError('Preserve prior native result;do not repeat unchanged')
    prepared = json.loads((work / 'prepared.json').read_text())
    app = work / APP; baseline_app = Path(prepared['baseline']) / APP
    policy = app / 'Contents/Frameworks/WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
    if probe.digest(policy) != prepared['policySHA256']:
        raise ValueError('Prepared policy changed')
    verify(app, RESTRICTED_ID); verify(baseline_app, BASE_ID)
    admission = subprocess.run(['python3', '-B', str(probe.REPO / 'scripts/native-qa-readiness.py'),
                                '--check'], capture_output=True, text=True)
    (work / 'admission.json').write_text(admission.stdout)
    if admission.returncode:
        print(json.dumps({'status': 'native-deferred', 'readinessExit': admission.returncode})); return
    addresses = re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)\b',
                           subprocess.check_output(['/sbin/ifconfig'], text=True))
    address = next((x for x in addresses if ipaddress.ip_address(x).is_private
                    and not ipaddress.ip_address(x).is_loopback), None)
    if address is None: raise RuntimeError('Own private IPv4 required')
    marker = 'owned-' + uuid.uuid4().hex
    username, password = 'owned-fixture', uuid.uuid4().hex
    origin = relay = None; hosts = []
    result = {'status': 'FAIL', 'scope': 'standalone hardened fixed-port HTTP only',
              'policySHA256': prepared['policySHA256'], 'harnessSHA256': probe.digest(Path(__file__)),
              'controls': [], 'cleanup': {}, 'notarized': False}
    try:
        origin = probe.Endpoint(address, marker)
        authorities = ('owned-' + uuid.uuid4().hex + f'.invalid:{origin.port}', f'{address}:{origin.port}')
        relay = probe.Endpoint('127.0.0.1', marker, auth=b'Basic ' + base64.b64encode(
            f'{username}:{password}'.encode()), allowed=authorities, port=PORT)
        urls = ['http://' + authority + '/' for authority in authorities]

        def start(bundle, role, proxy):
            host = BundleHost(bundle, {'role': role, 'proxy': proxy, 'proxyPort': PORT,
                                      'username': username, 'password': password,
                                      'urls': urls, 'marker': marker}, work / (role + '.stderr'), True)
            hosts.append(host)
            ready = host.wait('ready')
            if ready.get('visible') is not True or ready.get('ownFramework') is not True:
                raise RuntimeError('Own headed framework not ready')
            return host

        b = start(baseline_app, 'independent-direct', False)
        a = start(app, 'restricted', True)

        def navigate(host, label, url, success, direct, relayed):
            before_direct, before_relay = origin.snapshot()['responses'], relay.snapshot()['responses']
            host.send({'case': label, 'url': url})
            event = host.wait('navigation'); time.sleep(.1)
            observed_direct = origin.snapshot()['responses'] - before_direct
            observed_relay = relay.snapshot()['responses'] - before_relay
            passed = event.get('success') is success and observed_direct == direct and observed_relay == relayed
            result['controls'].append({'case': label, 'passed': passed, 'success': event.get('success'),
                                       'code': event.get('code'), 'directResponses': observed_direct,
                                       'relayResponses': observed_relay})
            if not passed: raise RuntimeError('Control failed: ' + label)

        navigate(b, 'independent-direct-ready', urls[1], True, 1, 0)
        navigate(a, 'named-relay-ready', urls[0], True, 0, 1)
        network_files = [p for p in helper_paths(app) if 'Networking' in str(p)]
        mapped = subprocess.run(['/usr/sbin/lsof', '-t', *map(str, network_files)], capture_output=True, text=True)
        result['restrictedOwnNetworkingMapped'] = mapped.returncode == 0 and bool(mapped.stdout.strip())
        if not result['restrictedOwnNetworkingMapped']:
            raise RuntimeError('Restricted helper path not independently observed')
        navigate(a, 'private-direct-denied', urls[1], False, 0, 0)
        relay.refusing = True
        navigate(a, 'named-relay-refused', urls[0], False, 0, 0)
        navigate(a, 'private-while-refused', urls[1], False, 0, 0)
        navigate(b, 'independent-direct-during-refusal', urls[1], True, 1, 0)
        relay.refusing = False
        navigate(a, 'named-relay-recovered', urls[0], True, 0, 1)
        c = start(baseline_app, 'intentional-unconfined', True)
        navigate(c, 'unconfined-configured-proxy-bypass-control', urls[1], True, 1, 0)
        result['status'] = 'PASS'
    except Exception as error:
        result['failureType'] = type(error).__name__; result['failure'] = str(error)
    finally:
        result['cleanup']['hostsNormalExit'] = [host.stop() for host in reversed(hosts)]
        result['cleanup']['relayDrained'] = relay.stop() if relay else True
        result['cleanup']['originDrained'] = origin.stop() if origin else True
        paths = helper_paths(app) + helper_paths(baseline_app)
        absent = False; deadline = time.monotonic() + 8
        while paths and time.monotonic() < deadline:
            state = subprocess.run(['/usr/sbin/lsof', '-t', *map(str, paths)], capture_output=True, text=True)
            if state.returncode == 1 and not state.stdout.strip() and not state.stderr.strip():
                absent = True; break
            time.sleep(.2)
        result['cleanup']['ownHelpersAbsent'] = absent
        if (len(result['controls']) != 8 or not all(result['cleanup']['hostsNormalExit'])
                or not all(v for k, v in result['cleanup'].items() if k != 'hostsNormalExit')):
            result['status'] = 'FAIL'
        probe.write_json(report, result)
    print(json.dumps({'status': result['status'], 'controls': result['controls'], 'cleanup': result['cleanup']}))
    if result['status'] != 'PASS': raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'run'])
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'prepare':
        if args.baseline is None: parser.error('--baseline required')
        prepare(args.baseline, args.work)
    else: run(args.work)
