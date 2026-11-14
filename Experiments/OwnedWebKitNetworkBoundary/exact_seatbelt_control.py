#!/usr/bin/env python3
"""Exercise the exact signed NetworkProcess policy in an isolated test child."""
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import socket
import subprocess
import sys
import tempfile
from contextlib import ExitStack

BROKER_PORT = 45100
PAYLOAD = b'neantik-seatbelt-control'
POLICY = 'WebKit.framework/Versions/A/Resources/com.apple.WebKit.NetworkProcess.sb'
RESOLVER_SERVICES = (
    'com.apple.dnssd.service',
    'com.apple.system.opendirectoryd.libinfo',
)
MACH_POSITIVE_CONTROL = 'com.apple.familycontrols'


def apply_policy(profile, parameters):
    library = ctypes.CDLL('/usr/lib/libsandbox.1.dylib')
    initialize = library.sandbox_init_with_parameters
    initialize.argtypes = [
        ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_char_p),
        ctypes.POINTER(ctypes.c_char_p),
    ]
    initialize.restype = ctypes.c_int
    library.sandbox_free_error.argtypes = [ctypes.c_char_p]
    values = [os.fsencode(item) for pair in parameters.items() for item in pair]
    error = ctypes.c_char_p()
    if initialize(profile, 0, (ctypes.c_char_p * (len(values) + 1))(*values), ctypes.byref(error)):
        message = error.value.decode(errors='replace') if error.value else 'unknown error'
        if error.value:
            library.sandbox_free_error(error)
        raise RuntimeError(message)


def mach_lookup_permissions():
    library = ctypes.CDLL('/usr/lib/libsandbox.1.dylib', use_errno=True)
    check = library.sandbox_check
    check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    check.restype = ctypes.c_int
    # Match WebKit's Darwin SandboxSPI.h. This checks permission only and
    # deliberately does not look up or send a message to a Mach service.
    filter_global_name = 2
    no_report = ctypes.c_int.in_dll(library, 'SANDBOX_CHECK_NO_REPORT').value
    results = {}
    for service in (*RESOLVER_SERVICES, MACH_POSITIVE_CONTROL):
        result = check(os.getpid(), b'mach-lookup', filter_global_name | no_report, service.encode())
        if result not in (0, 1):
            raise RuntimeError(f'sandbox_check returned {result} (errno {ctypes.get_errno()})')
        results[service] = 'allowed' if result == 0 else 'denied'
    return results


def child(profile_path, fixture_path, configuration, *, check_mach=False):
    endpoints = json.loads(configuration)
    if profile_path:
        profile = Path(profile_path)
        apply_policy(profile.read_bytes(), {
            'HOME_DIR': fixture_path,
            'HOME_LIBRARY_PREFERENCES_DIR': fixture_path + '/Library/Preferences',
            'DARWIN_USER_TEMP_DIR': fixture_path + '/Temp',
            'DARWIN_USER_CACHE_DIR': fixture_path + '/Cache',
            'WEBKIT2_FRAMEWORK_DIR': str(profile.parents[3]),
        })
    results = mach_lookup_permissions() if check_mach else {}
    for name, family, kind, address in endpoints:
        try:
            with socket.socket(family, kind) as client:
                if kind == socket.SOCK_STREAM:
                    client.connect(tuple(address))
                    client.sendall(PAYLOAD)
                else:
                    client.sendto(PAYLOAD, tuple(address))
            results[name] = 'sent'
        except OSError as error:
            results[name] = errno.errorcode.get(error.errno, str(error.errno))
    os.write(1, json.dumps(results).encode() + b'\n')


def receive(listener, kind):
    try:
        if kind == socket.SOCK_DGRAM:
            return listener.recv(1024) == PAYLOAD
        client, _ = listener.accept()
        with client:
            client.settimeout(0.5)
            return client.recv(len(PAYLOAD), socket.MSG_WAITALL) == PAYLOAD
    except TimeoutError:
        return False


def run(stage_path, *, check_mach=False):
    stage = json.loads(stage_path.read_text())
    host = Path(stage['app']) / 'Contents/Helpers/webkit-v1/NeAntikWebKitHost.app'
    policy = host / 'Contents/Frameworks' / POLICY
    policy_hash = hashlib.sha256(policy.read_bytes()).hexdigest()
    host_info = plistlib.loads((host / 'Contents/Info.plist').read_bytes())
    if policy_hash != stage['qaNetworkSandboxSHA256'] or policy_hash != host_info['NeAntikWebKitNetworkSandboxSHA256']:
        raise ValueError('Signed policy, host pin and stage pin differ')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', stage['app']], check=True, timeout=60)

    with ExitStack() as stack:
        fixture_path = stack.enter_context(tempfile.TemporaryDirectory(prefix='neantik-seatbelt-'))
        if check_mach:
            trials = {
                name: run_child('--mach-child', policy_path, fixture_path, [])
                for name, policy_path in (('unconfined', ''), ('exactPolicy', str(policy)))
            }
            expected = {service: 'denied' for service in RESOLVER_SERVICES}
            expected[MACH_POSITIVE_CONTROL] = 'allowed'
            passed = all(value == 'allowed' for value in trials['unconfined'].values())
            passed = passed and trials['exactPolicy'] == expected
            return report(stage, policy_hash, 'mach-lookup', trials, passed)
        listeners = {}
        endpoints = []
        for suffix, family, address in (('v4', socket.AF_INET, '127.0.0.1'), ('v6', socket.AF_INET6, '::1')):
            for label, kind, port in (('broker-tcp', socket.SOCK_STREAM, BROKER_PORT),
                                      ('alternate-tcp', socket.SOCK_STREAM, 0),
                                      ('direct-udp', socket.SOCK_DGRAM, 0)):
                listener = stack.enter_context(socket.socket(family, kind))
                if family == socket.AF_INET6:
                    listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                listener.bind((address, port))
                listener.settimeout(0.25)
                if kind == socket.SOCK_STREAM:
                    listener.listen(1)
                name = f'{label}-{suffix}'
                listeners[name] = listener
                endpoints.append((name, family, kind, listener.getsockname()))

        trials = {}
        for trial, policy_path in (('unconfined', ''), ('exactPolicy', str(policy))):
            results = run_child('--child', policy_path, fixture_path, endpoints)
            trials[trial] = {
                name: {'send': results[name], 'received': receive(listeners[name], kind)}
                for name, _, kind, _ in endpoints
            }

    passed = all(result == {'send': 'sent', 'received': True}
                 for result in trials['unconfined'].values())
    for name, result in trials['exactPolicy'].items():
        if name.startswith('broker-'):
            passed &= result == {'send': 'sent', 'received': True}
        else:
            passed &= result['send'] in ('EPERM', 'EACCES') and not result['received']
    return report(stage, policy_hash, 'loopback-sockets', trials, passed)


def run_child(mode, policy_path, fixture_path, endpoints):
    return json.loads(subprocess.check_output(
        [sys.executable, '-B', __file__, mode, policy_path, fixture_path, json.dumps(endpoints)],
        timeout=10,
    ))


def report(stage, policy_hash, mode, trials, passed):
    print(json.dumps({
        'passed': passed, 'policySHA256': policy_hash,
        'stageArchiveSHA256': stage['sha256'], 'macOS': platform.mac_ver()[0],
        'architecture': platform.machine(), 'mode': mode, 'trials': trials,
    }, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    if sys.argv[1:2] in (['--child'], ['--mach-child']):
        child(*sys.argv[2:], check_mach=sys.argv[1] == '--mach-child')
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('stage', type=Path)
        parser.add_argument('--mach-only', action='store_true')
        args = parser.parse_args()
        sys.exit(run(args.stage.resolve(strict=True), check_mach=args.mach_only))
