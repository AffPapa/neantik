#!/usr/bin/env python3
"""Owned headed TLS tunnel controls; no production trust/profile changes."""
import argparse
import base64
import ipaddress
import json
import plistlib
from pathlib import Path
import re
import subprocess
import time
import uuid

import probe
from assemble_layout import clone
from bundle_probe import BundleHost
from confined_bundle_probe import APP, BASE_ID, PORT, helper_paths, verify
import tls_fixture as fixture
from tls_control import evaluate

RESTRICTED = BASE_ID + '.restricted.tls'
UNCONFINED = BASE_ID + '.unconfined.tls'
CONTROL_APP = 'Unconfined WebKit TLS QA.app'


def prepare(source, work):
    if work.exists(): raise ValueError('Preserve previous TLS assembly')
    baseline = json.loads((source / 'confined-native.json').read_text())
    if baseline['status'] != 'PASS': raise ValueError('Standalone HTTP boundary baseline required')
    work.mkdir(parents=True)
    developer = subprocess.check_output([str(probe.REPO / 'scripts/resolve-compatible-developer-dir.sh')], text=True).strip()
    host = work / 'TLSHost'
    import os
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-fmodules', '-arch', 'arm64',
                    '-mmacosx-version-min=26.5', '-framework', 'AppKit', '-framework', 'WebKit',
                    '-framework', 'Network', '-framework', 'Security',
                    str(Path(__file__).with_name('TLSHost.m')), '-o', str(host)],
                   env=dict(os.environ, DEVELOPER_DIR=developer), check=True, capture_output=True)
    subprocess.run(['/usr/bin/install_name_tool', '-change',
                    '/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit',
                    '@rpath/WebKit.framework/Versions/A/WebKit', '-add_rpath',
                    '@executable_path/../Frameworks', str(host)], check=True, capture_output=True)
    ent = work / 'host.entitlements.plist'
    ent.write_bytes(plistlib.dumps({'com.apple.security.cs.allow-dyld-environment-variables': True}))
    prepared = json.loads((source / 'prepared.json').read_text())
    original_policy = Path(prepared['baseline']) / APP / 'Contents/Frameworks/WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
    if probe.digest(original_policy) != prepared['policyInputSHA256']:
        raise ValueError('Unconfined control source changed')
    for name, identifier in [(APP, RESTRICTED), (CONTROL_APP, UNCONFINED)]:
        app = work / name; clone(source / APP, app)
        executable = app / 'Contents/MacOS/Host'; executable.unlink(); clone(host, executable)
        info_path = app / 'Contents/Info.plist'; info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = identifier; info_path.write_bytes(plistlib.dumps(info))
        if name == CONTROL_APP:
            policy = app / 'Contents/Frameworks/WebKit.framework/Resources/com.apple.WebKit.NetworkProcess.sb'
            policy.write_bytes(original_policy.read_bytes())
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', probe.IDENTITY, '--options', 'runtime',
                            '--timestamp=none', str(app / 'Contents/Frameworks/WebKit.framework')], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', probe.IDENTITY, '--options', 'runtime',
                        '--timestamp=none', '--entitlements', str(ent), str(app)], check=True, capture_output=True)
        verify(app, identifier)
    probe.write_json(work / 'prepared.json', {'status': 'prepared-only', 'sourceBoundary': str(source),
                     'hostSourceSHA256': probe.digest(Path(__file__).with_name('Host.m')),
                     'tlsSourceSHA256': probe.digest(Path(__file__).with_name('TLSHost.m')),
                     'nativeLaunched': False, 'notarized': False, 'compileCount': 1,
                     'restrictedHostSHA256': probe.digest(work / APP / 'Contents/MacOS/Host'),
                     'unconfinedHostSHA256': probe.digest(work / CONTROL_APP / 'Contents/MacOS/Host')})
    print(json.dumps({'status': 'prepared-and-strict-verified', 'hostCompilations': 1}))


class TLSHost(BundleHost):
    def __init__(self, *args):
        self.validations = []
        super().__init__(*args)

    def read(self):
        for line in self.process.stdout:
            try:
                event = json.loads(line)
                if event.get('event') == 'tls-validation': self.validations.append(event.get('success'))
                self.events.put(event)
            except (ValueError, UnicodeError): self.events.put({'event': 'invalid-output'})


def run(work, continue_certificate_controls=False, finish_remaining=False):
    stem = ('tls-native-remaining' if finish_remaining else
            'tls-native-certificate-count-correction' if continue_certificate_controls else 'tls-native')
    report = work / (stem + '.json')
    if report.exists(): raise ValueError('Preserve previous TLS result;diagnose before retry')
    prepared = json.loads((work / 'prepared.json').read_text())
    for name, identifier, pin in [(APP, RESTRICTED, 'restrictedHostSHA256'),
                                   (CONTROL_APP, UNCONFINED, 'unconfinedHostSHA256')]:
        app = work / name
        if probe.digest(app / 'Contents/MacOS/Host') != prepared[pin]: raise ValueError('Prepared host changed')
        verify(app, identifier)
    admission = subprocess.run(['python3', '-B', str(probe.REPO / 'scripts/native-qa-readiness.py'),
                                '--check'], capture_output=True, text=True)
    (work / (stem + '-admission.json')).write_text(admission.stdout)
    if admission.returncode:
        print(json.dumps({'status': 'native-deferred', 'readinessExit': admission.returncode})); return
    addresses = re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)\b', subprocess.check_output(['/sbin/ifconfig'], text=True))
    address = next((x for x in addresses if ipaddress.ip_address(x).is_private and not ipaddress.ip_address(x).is_loopback), None)
    if address is None: raise ValueError('Own private IPv4 required')
    marker = 'owned-' + uuid.uuid4().hex; username, password = 'owned-fixture', uuid.uuid4().hex
    origin = independent_origin = relay = None; hosts = []
    result = {'status': 'FAIL', 'scope': 'headed owned TLS origin via real CONNECT;not remote proxy certification',
              'controls': [], 'cleanup': {}, 'notarized': False,
              'harnessSHA256': probe.digest(Path(__file__)), 'source': prepared}
    certificate_root = work / ('ephemeral-certificates3' if finish_remaining else
                               'ephemeral-certificates2' if continue_certificate_controls else 'ephemeral-certificates')
    if finish_remaining:
        prior = json.loads((work / 'tls-native-certificate-count-correction.json').read_text())
        if (len(prior['controls']) != 6 or not all(x['passed'] for x in prior['controls'][:5])
                or prior['controls'][5]['case'] != 'independent-direct-during-tunnel-refusal'
                or prior['controls'][5]['success'] is not True
                or prior['controls'][5]['originHTTPResponses'] != 1
                or prior['controls'][5]['originTCPAccepted'] != 2):
            raise ValueError('Unexpected prior failure;no automatic continuation')
        result['reusedControls'] = prior['controls'][:5]
        result['continuationReason'] = 'Five controls retained;Direct positive had one HTTP request over two TCP attempts. Separate independent origin attribution and distinguish requests/attempts/tunnels;finish only remaining controls plus fresh-fixture tunnel/refusal setup. No app or runtime rebuild.'
    if continue_certificate_controls:
        prior = json.loads((work / 'tls-native.json').read_text())
        if (len(prior['controls']) != 3 or not all(x['passed'] for x in prior['controls'][:2])
                or prior['controls'][2]['case'] != 'wrong-hostname-certificate-refused'
                or prior['controls'][2]['originHTTPResponses'] != 0
                or prior['controls'][2]['tlsValidation'] != [False, False]):
            raise ValueError('Unexpected prior failure;no automatic retry')
        result['continuationReason'] = 'Prior hostname rejected twice with zero HTTP;replace false exact-one-attempt assumption with TCP/tunnel correspondence. Prior ephemeral keys removed;fresh trust fixture requires its own positives. No app/runtime recompilation or signature change.'
    try:
        fixture.certificates(certificate_root, address)
        origin = fixture.TLSOrigin(address, marker, certificate_root)
        independent_origin = fixture.TLSOrigin(address, marker, certificate_root)
        authorities = [fixture.NAME + f':{origin.port}', f'{address}:{origin.port}',
                       f'owned-wrong.invalid:{origin.port}']
        relay = fixture.Tunnel({authority: origin for authority in authorities},
                               fixture.authorization(username, password), port=PORT)
        urls = ['https://' + authority + '/' for authority in authorities]
        independent_url = f'https://{address}:{independent_origin.port}/'

        def start(name, role, proxied, root='ca'):
            host = TLSHost(work / name, {'role': role, 'proxy': proxied, 'proxyPort': PORT,
                           'username': username, 'password': password,
                           'urls': urls + [independent_url], 'marker': marker,
                           'qaRootDER': base64.b64encode((certificate_root / (root + '.der')).read_bytes()).decode()},
                           work / (role + '.stderr'), True)
            hosts.append(host)
            ready = host.wait('ready')
            if ready.get('visible') is not True or ready.get('ownFramework') is not True:
                raise RuntimeError('Own headed TLS host not ready')
            return host

        def navigate(host, label, url, expected_success, expected_responses, expected_tunnels, validation=None,
                     measured_origin=None):
            measured_origin = measured_origin or origin
            before = measured_origin.snapshot()['responses']; tunnels = relay.authenticated_for(measured_origin)
            before_tcp = measured_origin.snapshot()['accepted']
            validations = len(host.validations)
            host.send({'case': label, 'url': url}); event = host.wait('navigation'); time.sleep(.1)
            observed = measured_origin.snapshot()['responses'] - before
            observed_tunnels = relay.authenticated_for(measured_origin) - tunnels
            observed_tcp = measured_origin.snapshot()['accepted'] - before_tcp
            tls_events = host.validations[validations:]
            route = ('relay' if expected_tunnels else 'direct' if expected_success else 'blocked')
            passed = evaluate(event=event, label=label, expected_success=expected_success,
                              responses=observed, tcp=observed_tcp, tunnels=observed_tunnels,
                              expected_responses=expected_responses, route=route,
                              trust_events=tls_events, expected_trust=validation)
            result['controls'].append({'case': label, 'passed': passed, 'success': event.get('success'),
                                       'code': event.get('code'), 'originHTTPResponses': observed,
                                       'actualNavigationCase': event.get('case'),
                                       'originTCPAccepted': observed_tcp,
                                       'authenticatedTunnels': observed_tunnels, 'tlsValidation': tls_events})
            if not passed: raise RuntimeError('TLS control failed: ' + label)

        b = start(CONTROL_APP, 'tls-direct', False)
        a = start(APP, 'tls-restricted', True)
        if not finish_remaining:
            navigate(b, 'independent-direct-trusted-TLS', independent_url, True, 1, 0, True,
                     measured_origin=independent_origin)
        navigate(a, 'trusted-TLS-through-authenticated-tunnel', urls[0], True, 1, 1, True)
        mapped = subprocess.run(['/usr/sbin/lsof', '-t', *[str(p) for p in helper_paths(work / APP)
                                                        if 'Networking' in str(p)]], capture_output=True, text=True)
        result['restrictedOwnNetworkingMapped'] = mapped.returncode == 0 and bool(mapped.stdout.strip())
        if not result['restrictedOwnNetworkingMapped']: raise RuntimeError('Own TLS Networking helper absent')
        if not finish_remaining:
            navigate(a, 'wrong-hostname-certificate-refused', urls[2], False, 0, 'certificate-refusal-attempts', False)
            navigate(a, 'private-HTTPS-direct-denied', urls[1], False, 0, 0)
        relay.refusing = True
        navigate(a, 'tunnel-refusal-no-Direct', urls[0], False, 0, 0)
        navigate(b, 'independent-direct-during-tunnel-refusal', independent_url, True, 1, 0,
                 measured_origin=independent_origin)
        relay.refusing = False
        navigate(a, 'trusted-TLS-tunnel-recovered', urls[0], True, 1, 1)
        for host in [a, b]:
            if not host.stop(): raise RuntimeError('TLS host failed graceful exit')
            hosts.remove(host)
        wrong = start(APP, 'tls-wrong-anchor', True, 'wrong-ca')
        navigate(wrong, 'wrong-CA-refused', urls[0], False, 0, 'certificate-refusal-attempts', False)
        if not wrong.stop(): raise RuntimeError('Wrong-anchor host failed exit')
        hosts.remove(wrong)
        negative = start(CONTROL_APP, 'tls-intentional-bypass', True)
        navigate(negative, 'unconfined-configured-proxy-HTTPS-bypass-control', urls[1], True, 1, 0, True)
        result['status'] = 'PASS'
    except Exception as error:
        result['failureType'] = type(error).__name__; result['failure'] = str(error)
    finally:
        result['cleanup']['hostsNormalExit'] = [host.stop() for host in reversed(hosts)]
        result['cleanup']['relayDrained'] = relay.stop() if relay else True
        result['cleanup']['originDrained'] = origin.stop() if origin else True
        result['cleanup']['independentOriginDrained'] = independent_origin.stop() if independent_origin else True
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
            for file in certificate_root.glob('*.key'):
                file.unlink(); deleted += 1
        result['cleanup']['ephemeralKeysRemoved'] = deleted == 3
        if (len(result['controls']) != (6 if finish_remaining else 9) or not all(result['cleanup']['hostsNormalExit'])
                or not all(v for k, v in result['cleanup'].items() if k != 'hostsNormalExit')):
            result['status'] = 'FAIL'
        probe.write_json(report, result)
    print(json.dumps({'status': result['status'], 'controls': result['controls'], 'cleanup': result['cleanup']}))
    if result['status'] != 'PASS': raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'run']); parser.add_argument('--source', type=Path)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--continue-certificate-controls', action='store_true')
    parser.add_argument('--finish-remaining', action='store_true')
    args = parser.parse_args()
    if args.action == 'prepare':
        if args.source is None: parser.error('--source required')
        prepare(args.source, args.work)
    else: run(args.work, args.continue_certificate_controls, args.finish_remaining)
