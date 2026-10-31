#!/usr/bin/env python3
"""Read one owned GUI session, metadata and kernel leases. Never launch a browser.

Only the two synthetic profiles made by manager-route-fixture.py are accepted.
Raw metadata, argv, URLs and paths remain in memory. The output is a private,
minimized receipt, not evidence of a DNS route without the independent ledger.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import time
import uuid

PHASES = ('before-launch', 'proxy-success', 'dns-refused', 'direct-control', 'proxy-recovered')


def require(condition, reason):
    if not condition: raise ValueError(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def sha(value): return hashlib.sha256(value).hexdigest()


def read_private(path, limit=2_000_000):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and not info.st_mode & 0o077 and info.st_nlink == 1
                and info.st_size <= limit, 'unsafe-owned-input')
        raw = os.read(fd, limit + 1)
        require(len(raw) <= limit, 'unbounded-owned-input')
        return raw
    finally: os.close(fd)


def load(path): return json.loads(read_private(path))


def write_new(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream: stream.write(canonical(value) + b'\n')


class BSDInfo(ctypes.Structure):
    # Public macOS SDK sys/proc_info.h, PROC_PIDTBSDINFO. A size or PID mismatch
    # fails rather than silently accepting another ABI or a reused process.
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('seconds', ctypes.c_uint64), ('microseconds', ctypes.c_uint64)]


def kernel_process(pid, executable):
    require(sys.platform == 'darwin' and type(pid) is int and pid > 1, 'macos-owned-pid-required')
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    info = BSDInfo()
    require(ctypes.sizeof(info) == 136 and library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), 136) == 136
            and info.pid == pid and info.uid == os.getuid() and info.seconds > 0
            and info.microseconds < 1_000_000, 'kernel-generation-unavailable')
    buffer = ctypes.create_string_buffer(4096)
    require(library.proc_pidpath(pid, buffer, len(buffer)) > 0
            and Path(os.fsdecode(buffer.value)).resolve() == executable.resolve(), 'live-executable-mismatch')
    # csops CS_OPS_CDHASH=5 returns the running code's primary 20-byte CDHash.
    code = ctypes.create_string_buffer(20)
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    require(libc.csops(pid, 5, ctypes.byref(code), 20) == 0, 'live-code-identity-unavailable')
    metadata = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(executable)],
                              capture_output=True, text=True, timeout=5)
    require(metadata.returncode == 0, 'static-code-identity-unavailable')
    cdhash = re.search(r'^CDHash=([0-9a-f]{40})$', metadata.stderr, re.M)
    require(cdhash is not None and cdhash[1] == code.raw.hex(), 'live-static-code-mismatch')
    return dict(pid=pid, parentPID=info.ppid, uid=info.uid, startSeconds=info.seconds,
                startMicroseconds=info.microseconds, cdhash=code.raw.hex())


def process_path(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    buffer = ctypes.create_string_buffer(4096)
    require(library.proc_pidpath(pid, buffer, len(buffer)) > 0, 'peer-path-unavailable')
    return Path(os.fsdecode(buffer.value)).resolve()


def socket_owner(output, edge):
    pid, found = None, set()
    for line in output.splitlines():
        if line.startswith('p'):
            require(line[1:].isdigit(), 'invalid-socket-pid')
            pid = int(line[1:])
        elif line == 'n' + edge:
            require(pid is not None, 'socket-pid-missing')
            found.add(pid)
    require(len(found) == 1, 'ambiguous-or-missing-socket-owner')
    return found.pop()


def socket_peer(state, root, channel, *, direct):
    """Bind this accepted TCP connection to a live relay or Chromium helper.

    Knowing that Chromium is alive is insufficient: a different local client
    must not be able to manufacture a browser PASS. The source/destination
    tuple comes from this accepted socket and lsof checks the matching client.
    """
    try:
        profile = state['profiles'][1 if direct else 0]
        lock_path = root / 'manager-data/Profiles' / profile['id'] / '.neantik.lock'
        raw = read_private(lock_path); lease = json.loads(raw)
        require(lease['schemaVersion'] == 3 and lease['phase'] == 'running' and lease['managerPID'] == state['managerPID'], 'peer-lease-not-running')
        app = Path(state['app']); manager_exe = app / 'Contents/MacOS/NeAntik'
        browser_bundle = app / 'Contents/Resources/NeAntik Browser.app'
        browser_exe = browser_bundle / 'Contents/MacOS/NeAntik Browser'
        manager = kernel_process(state['managerPID'], manager_exe)
        browser = kernel_process(lease['pid'], browser_exe)
        require(browser['parentPID'] == manager['pid'], 'peer-browser-parent')
        client, server = channel.getpeername(), channel.getsockname()
        require(client[0] == server[0] == '127.0.0.1', 'non-loopback-fixture-peer')
        edge = f'127.0.0.1:{client[1]}->127.0.0.1:{server[1]}'
        args = ['/usr/sbin/lsof', '-nP', '-iTCP@127.0.0.1:' + str(server[1]), '-Fpn']
        if not direct:
            relay = lease['relay']
            require(relay['profileID'].lower() == profile['id'].lower()
                    and relay['sessionGeneration'] == lease['ownerToken'], 'peer-relay-lease-mismatch')
            args[1:1] = ['-a', '-p', str(relay['ownerPID'])]
        result = subprocess.run(args, capture_output=True, text=True, timeout=4)
        require(result.returncode == 0, 'peer-socket-inventory-unavailable')
        pid = socket_owner(result.stdout, edge)
        chain, paths = [], []
        if direct:
            # Network Service usually owns the socket. Admit only a continuous
            # exact-code, same-UID helper chain ending at this owned browser.
            for _ in range(4):
                path = process_path(pid)
                require(path == browser_exe.resolve() or
                        (path.is_relative_to((browser_bundle / 'Contents/Frameworks').resolve())
                         and path.name.startswith('NeAntik Browser Helper')), 'peer-not-owned-browser-code')
                item = kernel_process(pid, path); chain.append(item); paths.append(path)
                if item == browser: break
                pid = item['parentPID']
            require(chain[-1] == browser, 'peer-not-descendant-of-owned-browser')
        else:
            owner = kernel_process(pid, manager_exe)
            require(owner['pid'] == relay['ownerPID'] and owner['parentPID'] == manager['pid']
                    and owner['startSeconds'] == relay['ownerStartSeconds'] and owner['startMicroseconds'] == relay['ownerStartMicroseconds']
                    and owner['uid'] == relay['ownerUID'], 'peer-not-owned-relay-generation')
            chain, paths = [owner], [manager_exe]
        require(read_private(lock_path) == raw and kernel_process(manager['pid'], manager_exe) == manager
                and kernel_process(browser['pid'], browser_exe) == browser, 'peer-custody-changed')
        require(all(kernel_process(item['pid'], path) == item for item, path in zip(chain, paths)), 'peer-owner-generation-changed')
        return dict(manager=manager, browser=browser, peerChain=chain, sessionGeneration=lease['ownerToken'].lower(),
                    profileID=profile['id'].lower(), socketTupleSHA256=sha(edge.encode()),
                    configurationSHA256=None if direct else relay['configurationSHA256'])
    except (KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        raise ValueError('peer-custody-unavailable') from None


def parse_argv(raw):
    require(len(raw) >= 6, 'invalid-kernel-argv')
    count = struct.unpack_from('=i', raw)[0]
    require(1 <= count <= 1024, 'invalid-kernel-argc')
    end = raw.find(b'\0', 4)
    require(end > 4, 'invalid-kernel-executable')
    offset = end + 1
    while offset < len(raw) and raw[offset] == 0: offset += 1
    args = []
    for _ in range(count):
        end = raw.find(b'\0', offset)
        require(end >= offset, 'truncated-kernel-argv')
        args.append(os.fsdecode(raw[offset:end])); offset = end + 1
    return args


def argv_for(pid):
    # macOS KERN_PROCARGS2 preserves token boundaries, including spaces in the
    # executable and resolver rules. ps substring checks cannot prove flags.
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(0)
    require(libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) == 0
            and 6 <= size.value <= 1_048_576, 'owned-argv-size-unavailable')
    buffer = ctypes.create_string_buffer(size.value)
    require(libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) == 0, 'owned-argv-unavailable')
    return parse_argv(buffer.raw[:size.value])


def flag(args, name, expected):
    require('--' not in args, 'switch-terminator-not-admitted')
    values = [a for a in args if a.startswith('-') and a.split('=', 1)[0].lstrip('-') == name.lstrip('-')]
    require(values == [name if expected is None else name + '=' + expected], 'ambiguous-or-wrong-route-flag')


def metadata_identity(profile):
    # Only the production markLaunched transition may differ. This hash covers
    # *all* remaining fields, including identity, proxy, startURL and future ones.
    return sha(canonical({k:v for k,v in profile.items() if k not in ('revision', 'updatedAt', 'lastLaunchedAt')}))


def configuration_digest(profile):
    proxy = profile['proxy']
    fields = [profile['id'].lower(), str(profile['revision']), proxy['kind'], proxy['host'],
              str(proxy['port']), proxy['username']]
    # Swift JSONSerialization canonical array; these fixture-only fields are
    # ASCII and contain no slash, so the encodings agree without escapes.
    return sha(json.dumps(fields, ensure_ascii=False, separators=(',', ':')).encode())


def owned_state(path):
    state = load(path)
    root = Path(state['root'])
    require(root.parent == Path('/private/tmp') and root.name.startswith('neantik-update-audit-')
            and str(uuid.UUID(root.name.removeprefix('neantik-update-audit-'))) == root.name.removeprefix('neantik-update-audit-'),
            'owned-root-required')
    info = root.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
            'unsafe-owned-root')
    require(state['data'] == str(root / 'manager-data') and state['manifest'] == str(root / 'candidate-manifest.json')
            and state['dnsFixture']['mode'] == 'manager-dns' and len(state['profiles']) == 2
            and [p['name'] for p in state['profiles']] == ['QA route proxy', 'QA route direct'], 'wrong-fixture-state')
    for profile in state['profiles']: require(str(uuid.UUID(profile['id'])).lower() == profile['id'].lower(), 'invalid-profile-id')
    return state, root


def capture(state, root, phase, *, physical_tcp=False, manager_webrtc=False, manager_websocket=False, manager_durability=False, manager_crash=False):
    # Closed fixtures share kernel/lease checks with explicit mode/source
    # bindings; they are not relabeled DNS evidence. CLI defaults stay DNS.
    require(sum(bool(value) for value in (physical_tcp, manager_webrtc, manager_websocket, manager_durability, manager_crash)) <= 1, 'ambiguous-fixture-mode')
    if manager_crash:
        require(state['crashFixture']['mode'] == 'manager-main-crash' and phase == 'direct-control', 'wrong-crash-fixture')
        bindings = dict(crashFixtureSHA256=state['crashFixtureSHA256'], crashProbeSHA256=state['crashProbeSHA256'], peerCollectorSHA256=state['peerCollectorSHA256'])
    elif manager_durability:
        require(state['durabilityFixture']['mode'] == 'manager-data-durability' and phase == 'direct-control', 'wrong-durability-fixture')
        bindings = dict(durabilityFixtureSHA256=state['durabilityFixtureSHA256'], durabilityProbeSHA256=state['durabilityProbeSHA256'])
    elif manager_websocket:
        require(state['websocketFixture']['mode'] == 'manager-websocket', 'wrong-websocket-fixture')
        bindings = dict(websocketFixtureSHA256=state['websocketFixtureSHA256'], websocketProbeSHA256=state['websocketProbeSHA256'])
    elif manager_webrtc:
        require(state['webrtcFixture']['mode'] == 'manager-webrtc', 'wrong-webrtc-fixture')
        bindings = dict(webrtcFixtureSHA256=state['webrtcFixtureSHA256'], webrtcProbeSHA256=state['webrtcProbeSHA256'])
    elif physical_tcp:
        require(state['tcpFixture']['mode'] == 'manager-physical-tcp', 'wrong-tcp-fixture')
        bindings = dict(tcpFixtureSHA256=state['tcpFixtureSHA256'])
    else:
        bindings = dict(dnsFixtureSHA256=state['dnsFixtureSHA256'],
                        dnsWireFixtureSHA256=state['dnsWireFixtureSHA256'])
    app = Path(state['app']); executable = app / 'Contents/MacOS/NeAntik'
    manifest_bytes = read_private(root / 'candidate-manifest.json')
    require(sha(manifest_bytes) == state['candidateManifestSHA256'], 'manifest-changed')
    manifest = json.loads(manifest_bytes)
    require(sha(executable.read_bytes()) == state['managerSHA256'], 'manager-changed')
    manager = kernel_process(state['managerPID'], executable)
    manager_argv = argv_for(manager['pid'])
    require(manager_argv == [str(executable), '--neantik-release-update-audit', '--candidate-manifest',
                str(root / 'candidate-manifest.json').replace('/private/tmp/', '/tmp/'), '--output', state['output']], 'wrong-manager-mode')
    data = root / 'manager-data'; raw = read_private(data / 'profiles.json')
    document = json.loads(raw)
    profiles = document if isinstance(document, list) else document['profiles']
    wanted = state['profiles'][1 if phase == 'direct-control' else 0]
    selected = [p for p in profiles if p['id'].lower() == wanted['id'].lower()]
    require(len(selected) == 1 and len(profiles) == 2 and selected[0]['name'] == wanted['name'], 'wrong-profile')
    profile = selected[0]
    require(type(profile['revision']) is int and profile['revision'] >= 0 and profile['engine'] == 'chromium', 'wrong-profile-revision-engine')
    is_direct = phase == 'direct-control'
    if not is_direct:
        require(profile.get('proxy') == dict(kind='http', host='127.0.0.1', port=state['proxyPort'], username='owned-fixture-user'),
                'synthetic-proxy-not-configured')
    else: require(profile.get('proxy') is None, 'direct-control-proxy-configured')
    result = dict(phase=phase, at=time.monotonic(), manager=manager,
        profileID=profile['id'].lower(), revision=profile['revision'], metadataIdentitySHA256=metadata_identity(profile),
        lastLaunchedAt=profile.get('lastLaunchedAt'), updatedAt=profile['updatedAt'],
        managerSHA256=state['managerSHA256'], candidateManifestSHA256=state['candidateManifestSHA256'],
        fixtureSHA256=state['fixtureSHA256'], **bindings,
        collectorSHA256=sha(Path(__file__).read_bytes()), version=state['version'], build=state['build'])
    if phase == 'before-launch':
        require(not (data / 'Profiles' / profile['id'] / '.neantik.lock').exists(), 'profile-already-launched')
        result['configurationSHA256'] = configuration_digest(profile)
        # Direct baseline is collected now, before either browser exists.
        direct = next(p for p in profiles if p['id'].lower() == state['profiles'][1]['id'].lower())
        require(direct.get('proxy') is None and direct.get('lastLaunchedAt') is None, 'direct-baseline-used')
        result['directBaseline'] = dict(profileID=direct['id'].lower(), revision=direct['revision'],
                                       metadataIdentitySHA256=metadata_identity(direct))
    else:
        lock_path = data / 'Profiles' / profile['id'] / '.neantik.lock'
        lock_raw = read_private(lock_path); lease = json.loads(lock_raw)
        expected_browser = app / 'Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser'
        expected_data = data / 'Profiles' / profile['id'] / 'BrowserData'
        require(lease['schemaVersion'] == 3 and lease['phase'] == 'running'
                and lease['managerPID'] == manager['pid'] and lease.get('pendingRelayOwner') is None
                and Path(lease['executablePath']).resolve() == expected_browser.resolve()
                and Path(lease['browserDataPath']).resolve() == expected_data.resolve(), 'invalid-running-lease')
        browser = kernel_process(lease['pid'], expected_browser)
        require(browser['parentPID'] == manager['pid'], 'browser-not-child-of-manager')
        command = argv_for(browser['pid'])
        flag(command, '--use-mock-keychain', None)
        flag(command, '--user-data-dir', str(expected_data))
        require(not any(a.startswith('-') and a.split('=',1)[0].lstrip('-') == f.lstrip('-') for a in command for f in ('--remote-debugging-port',
                    '--remote-debugging-pipe', '--password-store', '--disable-web-security', '--ignore-certificate-errors',
                    '--disable-gpu', '--headless', '--proxy-pac-url', '--proxy-auto-detect')), 'wrong-browser-launch-policy')
        require(not any(a.startswith('--proxy-server=') and '@' in a for a in command), 'credential-in-proxy-argv')
        result.update(browser=browser, sessionGeneration=lease['ownerToken'].lower(), leaseSHA256=sha(lock_raw))
        relay = lease.get('relay')
        if is_direct:
            require(relay is None and not any(a.startswith('-') and a.split('=',1)[0].lstrip('-') == 'proxy-server' for a in command), 'direct-control-not-direct')
            flag(command, '--no-proxy-server', None)
        else:
            require(isinstance(relay, dict) and relay['profileID'].lower() == result['profileID']
                    and relay['sessionGeneration'].lower() == result['sessionGeneration'], 'relay-profile-session-mismatch')
            owner = kernel_process(relay['ownerPID'], executable)
            require(owner['parentPID'] == manager['pid'] and owner['startSeconds'] == relay['ownerStartSeconds']
                    and owner['startMicroseconds'] == relay['ownerStartMicroseconds'] and owner['uid'] == relay['ownerUID'],
                    'relay-generation-mismatch')
            require(argv_for(owner['pid']) == [str(executable), '--neantik-proxy-relay-owner-v1'], 'relay-owner-mode')
            port = relay['loopbackPort']
            require(type(port) is int and 1 <= port <= 65535, 'relay-port-invalid')
            flag(command, '--proxy-server', 'socks5://127.0.0.1:' + str(port))
            require(not any(a.startswith('-') and a.split('=',1)[0].lstrip('-') == 'no-proxy-server' for a in command), 'conflicting-direct-flag')
            flag(command, '--proxy-bypass-list', '<-loopback>')
            flag(command, '--host-resolver-rules', 'MAP * ~NOTFOUND, EXCLUDE 127.0.0.1')
            flag(command, '--disable-quic', None)
            for key, manifest_key in [('runtimeExecutableSHA256', 'runtimeExecutable'),
                                      ('runtimeFrameworkSHA256', 'runtimeFramework')]:
                # Manifest is already byte-verified by the fixture. Locate its
                # exact relative path; never infer a runtime hash from version.
                require(manifest['criticalFiles'][manifest_key]['sha256'] == relay[key], 'runtime-manifest-binding')
            result.update(relay=relay, relayOwner=owner, configurationSHA256=relay['configurationSHA256'])
            require(kernel_process(owner['pid'], executable) == owner, 'relay-owner-changed-during-observation')
        require(read_private(lock_path) == lock_raw, 'lease-changed-during-observation')
        require(kernel_process(browser['pid'], expected_browser) == browser, 'browser-changed-during-observation')
    require(read_private(data / 'profiles.json') == raw and kernel_process(manager['pid'], executable) == manager,
            'metadata-or-manager-changed-during-observation')
    return result


def receipt_directory(state_path):
    directory = state_path.resolve().parent
    info = directory.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
            'private-receipt-directory-required')
    return directory


def cleanup(state, root, receipts):
    samples = [load(receipts / ('dns-custody-' + phase + '.json')) for phase in PHASES]
    pids = {p['pid'] for s in samples for key in ('manager', 'browser', 'relayOwner') if (p := s.get(key))}
    inventory = subprocess.check_output(['/bin/ps', '-axo', 'pid=,uid=,command='], text=True, timeout=5)
    remaining = []
    for line in inventory.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3: continue
        pid, uid, command = parts
        if int(pid) in pids or (int(uid) == os.getuid() and (str(root) in command or str(root).replace('/private/tmp/', '/tmp/') in command)):
            # This collector itself has only the state filename in argv, not
            # the owned app root. Any app/relay/helper match is conservatively
            # unfinished; do not signal, kill or disclose its command line.
            remaining.append(int(pid))
    return dict(schemaVersion=1, at=time.monotonic(), ownedProcessesRemaining=len(remaining),
                collectorSHA256=sha(Path(__file__).read_bytes()), ordinaryInstanceTouched=False,
                gracefulCloseQualified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--phase', choices=(*PHASES, 'cleanup'), required=True)
    args = parser.parse_args()
    try:
        state, root = owned_state(args.state)
        receipts = receipt_directory(args.state)
        value = cleanup(state, root, receipts) if args.phase == 'cleanup' else capture(state, root, args.phase)
        output = receipts / ('dns-custody-' + args.phase + '.json')
        write_new(output, value)
    except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
        print(json.dumps(dict(result='FAIL', reason='owned-custody-refused', browserQualification=False)))
        raise SystemExit(1)
    print(json.dumps(dict(result='captured', phase=args.phase, browserQualification=False)))


if __name__ == '__main__': main()
