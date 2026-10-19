#!/usr/bin/env python3
"""Isolated WebRTC/UDP and delegated-DNS-denial development fixture."""
import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time
import uuid

import probe
from assemble_layout import clone
from bundle_probe import BundleHost
from confined_bundle_probe import APP, BASE_ID, PORT, helper_paths, verify
from tls_bundle_probe import CONTROL_APP
import tls_fixture as tls
from stun_fixture import OwnedSTUN

RESTRICTED = BASE_ID + '.network.restricted'
UNCONFINED = BASE_ID + '.network.unconfined'
DNS_DENIAL = '''
; NeAntik research: no delegation to the system DNS/libinfo endpoints.
; This is source hardening, not proof that all possible delegation is covered.
(deny mach-lookup
    (global-name "com.apple.dnssd.service")
    (global-name "com.apple.system.opendirectoryd.libinfo"))
'''


def prepare(source, work):
    if work.exists(): raise ValueError('Preserve previous network QA assembly')
    previous = json.loads((source / 'tls-native-remaining.json').read_text())
    if previous['status'] != 'PASS': raise ValueError('Standalone TLS setup baseline required')
    work.mkdir(parents=True)
    developer = subprocess.check_output([str(probe.REPO / 'scripts/resolve-compatible-developer-dir.sh')], text=True).strip()
    host = work / 'NetworkHost'
    compilation = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-fmodules', '-arch', 'arm64',
                    '-mmacosx-version-min=26.5', '-framework', 'AppKit', '-framework', 'WebKit',
                    '-framework', 'Network', '-framework', 'Security',
                    str(Path(__file__).with_name('NetworkHost.m')), '-o', str(host)],
                   env=dict(os.environ, DEVELOPER_DIR=developer), capture_output=True)
    (work / 'compile.stderr').write_bytes(compilation.stderr)
    if compilation.returncode: raise RuntimeError('NetworkHost compilation failed;retain compiler receipt')
    subprocess.run(['/usr/bin/install_name_tool', '-change',
                    '/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit',
                    '@rpath/WebKit.framework/Versions/A/WebKit', '-add_rpath',
                    '@executable_path/../Frameworks', str(host)], check=True, capture_output=True)
    ent = work / 'host.entitlements.plist'
    ent.write_bytes(plistlib.dumps({'com.apple.security.cs.allow-dyld-environment-variables': True}))
    probe.compile_overlay(DNS_DENIAL)
    for name, identifier in [(APP, RESTRICTED), (CONTROL_APP, UNCONFINED)]:
        app = work / name; clone(source / name, app)
        executable = app / 'Contents/MacOS/Host'; executable.unlink(); clone(host, executable)
        info_path = app / 'Contents/Info.plist'; info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = identifier; info_path.write_bytes(plistlib.dumps(info))
        clone(Path(__file__).with_name('network_observation.js'), app / 'Contents/Resources/network_observation.js')
        if name == APP:
            policy = app / 'Contents/Frameworks/WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
            policy.write_text(policy.read_text() + DNS_DENIAL)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', probe.IDENTITY, '--options', 'runtime',
                            '--timestamp=none', str(app / 'Contents/Frameworks/WebKit.framework')], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', probe.IDENTITY, '--options', 'runtime',
                        '--timestamp=none', '--entitlements', str(ent), str(app)], check=True, capture_output=True)
        verify(app, identifier)
    probe.write_json(work / 'prepared.json', {'status': 'prepared-only', 'source': str(source),
                     'nativeLaunched': False, 'notarized': False, 'hostCompilations': 1,
                     'sourceInputs': {name: probe.digest(Path(__file__).with_name(name)) for name in
                        ['Host.m', 'TLSHost.m', 'NetworkHost.m', 'network_observation.js']},
                     'restrictedHostSHA256': probe.digest(work / APP / 'Contents/MacOS/Host'),
                     'unconfinedHostSHA256': probe.digest(work / CONTROL_APP / 'Contents/MacOS/Host'),
                     'policySHA256': probe.digest(work / APP / 'Contents/Frameworks/WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb')})
    print(json.dumps({'status': 'prepared-and-strict-verified', 'hostCompilations': 1}))


def complete_observation(event, label, nonce):
    value = event.get('result', {})
    return (event.get('case') == label and value.get('nonce') == nonce
            and all(value.get(key) is True for key in ['available', 'secureContext', 'offerCreated',
                                                       'gatheringComplete', 'closed'])
            and value.get('timedOut') is False)


def repair_script_resource(source, work, stun_target=False):
    """A separate copy preserves the failed signed assembly;no recompilation."""
    if work.exists(): raise ValueError('Preserve previous resource repair')
    prior = json.loads((source / 'network-native.json').read_text())
    expected_timeout = (len(prior['controls']) == 1
        and prior['controls'][0]['case'] == 'unconfined-direct-STUN-positive'
        and prior['controls'][0]['stunRequests'] > 0
        and prior['controls'][0]['observation']['candidates']['srflx'] > 0
        and prior['controls'][0]['observation']['timedOut'] is True)
    if prior['status'] != 'FAIL' or (not expected_timeout if stun_target else bool(prior['controls'])):
        raise ValueError('Unexpected prior stage;diagnose before repair')
    prepared = json.loads((source / 'prepared.json').read_text())
    work.mkdir(parents=True)
    ent = work / 'host.entitlements.plist'
    ent.write_bytes(plistlib.dumps({'com.apple.security.cs.allow-dyld-environment-variables': True}))
    for name, identifier, pin in [(APP, RESTRICTED, 'restrictedHostSHA256'),
                                  (CONTROL_APP, UNCONFINED, 'unconfinedHostSHA256')]:
        if probe.digest(source / name / 'Contents/MacOS/Host') != prepared[pin]:
            raise ValueError('Original host changed')
        app = work / name; clone(source / name, app)
        resource = app / 'Contents/Resources/network_observation.js'
        if probe.digest(resource) != prepared['sourceInputs']['network_observation.js']:
            raise ValueError('Original script changed')
        resource.write_bytes(Path(__file__).with_name('network_observation.js').read_bytes())
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', probe.IDENTITY, '--options', 'runtime',
                        '--timestamp=none', '--entitlements', str(ent), str(app)], check=True, capture_output=True)
        verify(app, identifier)
        prepared[pin] = probe.digest(app / 'Contents/MacOS/Host')
    prepared['resourceRepair'] = {'source': str(source), 'hostRecompiled': False,
        'originalScriptSHA256': prepared['sourceInputs']['network_observation.js'],
        'reason': 'async expression returns unsupported Promise to evaluateJavaScript;void leaves receipt delivery through the validated script message handler'}
    if stun_target:
        prepared['resourceRepair']['reason'] = 'Retain failed full ICE timeout;measure an explicit STUN response or URL-bound701 transaction outcome and close peer;not a full ICE completion claim'
        prepared['observationScope'] = 'STUN target transaction only;full ICE completion remains open'
    prepared['sourceInputs']['network_observation.js'] = probe.digest(Path(__file__).with_name('network_observation.js'))
    probe.write_json(work / 'prepared.json', prepared)
    print(json.dumps({'status': 'resource-repaired-and-strict-verified', 'hostRecompiled': False}))


def finished_stun_target(event, label, nonce, expect_packets):
    value = event.get('result', {})
    common = (event.get('case') == label and value.get('nonce') == nonce
              and all(value.get(key) is True for key in ['available', 'secureContext', 'offerCreated', 'closed'])
              and value.get('timedOut') is False)
    srflx = value.get('candidates', {}).get('srflx')
    if not common or type(srflx) is not int or srflx < 0: return False
    return srflx > 0 if expect_packets else srflx == 0 and (
        value.get('gatheringComplete') is True or 701 in value.get('errorCodes', []))


def run(work, finish_remaining=False):
    stem = 'network-native-remaining' if finish_remaining else 'network-native'
    report = work / (stem + '.json')
    if report.exists(): raise ValueError('Preserve previous network result;no unchanged retries')
    prepared = json.loads((work / 'prepared.json').read_text())
    for name, identifier, pin in [(APP, RESTRICTED, 'restrictedHostSHA256'),
                                 (CONTROL_APP, UNCONFINED, 'unconfinedHostSHA256')]:
        if probe.digest(work / name / 'Contents/MacOS/Host') != prepared[pin]:
            raise ValueError('Prepared host changed')
        verify(work / name, identifier)
    if probe.digest(work / APP / 'Contents/Frameworks/WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb') != prepared['policySHA256']:
        raise ValueError('Prepared policy changed')
    admission = subprocess.run(['python3', '-B', str(probe.REPO / 'scripts/native-qa-readiness.py'),
                                '--check'], capture_output=True, text=True)
    (work / (stem + '-admission.json')).write_text(admission.stdout)
    if admission.returncode:
        print(json.dumps({'status': 'native-deferred', 'readinessExit': admission.returncode})); return
    addresses = re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)\b', subprocess.check_output(['/sbin/ifconfig'], text=True))
    address = next((x for x in addresses if ipaddress.ip_address(x).is_private and not ipaddress.ip_address(x).is_loopback), None)
    if address is None: raise ValueError('Own private IPv4 required')
    nonce = uuid.uuid4().hex; marker = 'owned-' + nonce
    username, password = 'owned-fixture', uuid.uuid4().hex
    origin = relay = stun = None; hosts = []; stun_servers = []
    result = {'status': 'FAIL', 'scope': 'owned UDP4 STUN WebRTC only;DNS denial source not a complete DNS-on-wire gate',
              'controls': [], 'cleanup': {}, 'notarized': False,
              'harnessSHA256': probe.digest(Path(__file__)), 'inputs': prepared}
    certificate_root = work / ('ephemeral-certificates2' if finish_remaining else 'ephemeral-certificates')
    if finish_remaining:
        prior = json.loads((work / 'network-native.json').read_text())
        if (prior['status'] != 'FAIL' or len(prior['controls']) != 2
                or prior['controls'][0]['passed'] is not True
                or prior['controls'][1]['stunRequests'] != 0
                or prior['controls'][1]['observation']['gatheringComplete'] is not True
                or prior['controls'][1]['observation']['timedOut'] is not False):
            raise ValueError('Unexpected previous stage;no automatic continuation')
        result['reusedObservations'] = prior['controls']
        result['continuationReason'] = 'Own target positive observed;restricted gathering actually completed with zero candidates/UDP and no timeout. Accept actual completed gathering as well as URL-bound701 denial;retain first FAIL. Run only the two remaining proxy-removal conditions on the same signed bytes.'
    try:
        tls.certificates(certificate_root, address)
        origin = tls.TLSOrigin(address, marker, certificate_root)
        authorities = [tls.NAME + f':{origin.port}', f'{address}:{origin.port}']
        urls = ['https://' + authority + '/' for authority in authorities]
        relay = tls.Tunnel({authority: origin for authority in authorities},
                           tls.authorization(username, password), port=PORT)
        def next_stun_phase():
            nonlocal stun
            # Keep prior owned listeners bound until final cleanup so an old
            # UDP transaction cannot be attributed to another window/phase.
            stun = OwnedSTUN(address); stun_servers.append(stun)
            acknowledged = stun.verify_canary()
            result.setdefault('stunCanaries', []).append(acknowledged)
        next_stun_phase()
        result['stunCanaryAcknowledged'] = all(result['stunCanaries'])

        def start(name, role, proxied):
            host = BundleHost(work / name, {'role': role, 'proxy': proxied, 'proxyPort': PORT,
                    'username': username, 'password': password, 'urls': urls, 'marker': marker,
                    'nonce': nonce, 'stunHost': address, 'stunPort': stun.port,
                    'qaRootDER': base64.b64encode((certificate_root / 'ca.der').read_bytes()).decode()},
                    work / (role + '.stderr'), True)
            hosts.append(host)
            result['phase'] = role + ':page-setup'
            ready = host.wait('ready')
            if ready.get('visible') is not True or ready.get('ownFramework') is not True:
                raise RuntimeError('Own headed network host not ready')
            host.send({'case': role + '-page', 'url': urls[0 if proxied else 1]})
            navigation = host.wait('navigation')
            if navigation.get('case') != role + '-page' or navigation.get('success') is not True:
                raise RuntimeError('Own trusted page setup failed: ' + role)
            return host

        def observe(host, label, clear, expect_packets):
            result['phase'] = label
            before = stun.snapshot()
            host.send({'action': 'observe-rtc', 'case': label, 'clearProxy': clear})
            event = host.wait('network-observation', timeout=45)
            after = stun.snapshot()
            packets = after['browserRequests'] - before['browserRequests']
            invalid = after['invalidRequests'] - before['invalidRequests']
            finished = (finished_stun_target(event, label, nonce, expect_packets)
                        if prepared.get('observationScope') else complete_observation(event, label, nonce))
            passed = finished and invalid == 0
            passed = passed and (packets > 0 if expect_packets else packets == 0)
            result['controls'].append({'case': label, 'passed': passed, 'proxyIntentionallyCleared': clear,
                                       'actualObservationCase': event.get('case'),
                                       'stunRequests': packets, 'invalidPackets': invalid,
                                       'observation': event.get('result')})
            probe.write_json(work / (stem + '-progress.json'), result)
            print(json.dumps({'phase': label, 'passed': passed, 'stunRequests': packets}), flush=True)
            if not passed: raise RuntimeError('WebRTC control failed: ' + label)

        b = start(CONTROL_APP, 'unconfined-missing-proxy' if finish_remaining else 'unconfined-direct', finish_remaining)
        observe(b, 'unconfined-missing-proxy-STUN-positive-control' if finish_remaining
                else 'unconfined-direct-STUN-positive', finish_remaining, True)
        if not b.stop(): raise RuntimeError('Unconfined Direct host exit failed')
        hosts.remove(b)
        next_stun_phase()
        a = start(APP, 'restricted-proxy', True)
        mapped = subprocess.run(['/usr/sbin/lsof', '-t', *[str(p) for p in helper_paths(work / APP)
                                                        if 'Networking' in str(p)]], capture_output=True, text=True)
        result['restrictedOwnNetworkingMapped'] = mapped.returncode == 0 and bool(mapped.stdout.strip())
        if not result['restrictedOwnNetworkingMapped']: raise RuntimeError('Own Networking helper not observed')
        if not finish_remaining:
            observe(a, 'restricted-proxy-STUN-denied', False, False)
        observe(a, 'restricted-missing-proxy-STUN-denied', True, False)
        if not a.stop(): raise RuntimeError('Restricted host exit failed')
        hosts.remove(a)
        if not finish_remaining:
            next_stun_phase()
            negative = start(CONTROL_APP, 'unconfined-missing-proxy', True)
            observe(negative, 'unconfined-missing-proxy-STUN-positive-control', True, True)
        result['status'] = 'PASS'
    except Exception as error:
        result['failureType'] = type(error).__name__; result['failure'] = str(error)
    finally:
        result['cleanup']['hostsNormalExit'] = [host.stop() for host in reversed(hosts)]
        result['stunFinalCounts'] = [server.snapshot() for server in stun_servers]
        result['cleanup']['stunStopped'] = all([server.stop() for server in stun_servers])
        result['cleanup']['relayDrained'] = relay.stop() if relay else True
        result['cleanup']['originDrained'] = origin.stop() if origin else True
        paths = helper_paths(work / APP) + helper_paths(work / CONTROL_APP)
        absent = False; deadline = time.monotonic() + 8
        while paths and time.monotonic() < deadline:
            state = subprocess.run(['/usr/sbin/lsof', '-t', *map(str, paths)], capture_output=True, text=True)
            if state.returncode == 1 and not state.stdout.strip() and not state.stderr.strip():
                absent = True; break
            time.sleep(.2)
        result['cleanup']['ownHelpersAbsent'] = absent
        deleted = 0
        if certificate_root.exists():
            for file in certificate_root.glob('*.key'): file.unlink(); deleted += 1
        result['cleanup']['ephemeralKeysRemoved'] = deleted == 3
        if (len(result['controls']) != (2 if finish_remaining else 4) or not all(result['cleanup']['hostsNormalExit'])
                or not all(v for k, v in result['cleanup'].items() if k != 'hostsNormalExit')):
            result['status'] = 'FAIL'
        probe.write_json(report, result)
    print(json.dumps({'status': result['status'], 'controls': result['controls'], 'cleanup': result['cleanup']}))
    if result['status'] != 'PASS': raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'repair-script-resource', 'prepare-stun-target', 'run']); parser.add_argument('--source', type=Path)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--finish-remaining', action='store_true')
    args = parser.parse_args()
    if args.action in ('prepare', 'repair-script-resource', 'prepare-stun-target'):
        if args.source is None: parser.error('--source required')
        if args.action == 'prepare': prepare(args.source, args.work)
        else: repair_script_resource(args.source, args.work, args.action == 'prepare-stun-target')
    else: run(args.work, args.finish_remaining)
