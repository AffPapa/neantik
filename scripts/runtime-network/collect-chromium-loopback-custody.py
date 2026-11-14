#!/usr/bin/env python3
"""Bind an owned Chromium QA DevTools endpoint to the exact candidate and lease."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import uuid

from importlib import import_module

CORE = import_module('collect-manager-dns')
CRASH = import_module('collect-manager-crash')


def endpoint(raw):
    match = re.fullmatch(rb'([1-9][0-9]{0,4})\n(/devtools/browser/[0-9a-f-]{36})\n?', raw)
    CORE.require(match is not None, 'invalid-devtools-port-file')
    port = int(match[1])
    CORE.require(port <= 65535, 'invalid-devtools-port')
    path = match[2].decode('ascii')
    token = path.rsplit('/', 1)[-1]
    CORE.require(str(uuid.UUID(token)) == token, 'invalid-devtools-browser-token')
    return port, path


def listener_is_owned(output, pid, port):
    return re.fullmatch(rf'p{pid}\nf[0-9]+\nn127\.0\.0\.1:{port}\n?', output) is not None


def observe_stop(custody, data, status, *, generation_absent=CRASH.generation_absent):
    CORE.require(custody['status'] == 'observed' and custody['browserData'] == str(data)
                 and uuid.UUID(status['profileID']) == uuid.UUID(custody['profileID'])
                 and status['processState'] == 'stopped', 'stopped-profile-status-required')
    lease = data.parent / '.neantik.lock'
    CORE.require(not os.path.lexists(lease), 'browser-lease-still-present')
    CORE.require(generation_absent(custody['browser']), 'owned-browser-generation-still-live')
    CORE.require(not os.path.lexists(lease), 'browser-lease-reappeared')
    return {'candidateArchiveSHA256': custody['candidateArchiveSHA256'],
            'profileID': custody['profileID'], 'browserGeneration': custody['browser'],
            'generationAbsent': True, 'profileState': 'stopped'}


def collect(stage, archive_sha, root, profile_id, manager_pid, proxy_port):
    def private_dir(path):
        info = path.lstat()
        CORE.require(path.resolve(strict=True) == path and stat.S_ISDIR(info.st_mode)
                     and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
                     'unsafe-fixture-directory')

    private_dir(root)
    token = root.name.removeprefix('neantik-')
    CORE.require(root.parent == Path('/private/tmp') and root.name == 'neantik-' + str(uuid.UUID(token)),
                 'wrong-fixture-root')
    private_dir(stage.parent)
    CORE.require(stage.name == 'stage.json' and stage.parent.parent == Path('/private/tmp')
                 and stage.parent.name.startswith('neantik-owned-webkit-successor-qa-'),
                 'wrong-candidate-stage')
    stage_raw = CORE.read_private(stage, 16384)
    candidate = json.loads(stage_raw)
    app = stage.parent / 'NeAntik.app'
    CORE.require(re.fullmatch(r'[0-9a-f]{64}', archive_sha) is not None
                 and candidate['sha256'] == archive_sha
                 and candidate['app'] == str(app) and candidate['releaseQualified'] is False
                 and candidate['disposableDebugFixture'] is True, 'wrong-candidate-scope')
    manager = app / 'Contents/MacOS/NeAntik'
    browser = app / 'Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser'
    CORE.require(CORE.sha(manager.read_bytes()) == candidate['managerSignedSHA256'], 'manager-hash-mismatch')
    profile = root / 'Profiles' / str(profile_id).upper()
    data = profile / 'BrowserData'
    private_dir(data)
    lease_path = profile / '.neantik.lock'
    lease_raw = CORE.read_private(lease_path, 16384)
    lease = json.loads(lease_raw)
    CORE.require(lease['schemaVersion'] == 3 and lease['phase'] == 'running'
                 and lease['managerPID'] == manager_pid
                 and Path(lease['executablePath']).resolve(strict=True) == browser
                 and Path(lease['browserDataPath']).resolve(strict=True) == data
                 and lease.get('relay') is None,
                 'browser-lease-mismatch')
    owner = CORE.kernel_process(manager_pid, manager)
    process = CORE.kernel_process(lease['pid'], browser)
    CORE.require(process['parentPID'] == manager_pid, 'browser-parent-mismatch')
    CORE.require(CORE.argv_for(manager_pid)[1:] == ['--neantik-mcp-stdio',
                 '--neantik-mcp-loopback-qa-v1', str(root), str(proxy_port)], 'manager-qa-arguments-mismatch')
    args = CORE.argv_for(lease['pid'])
    data_flags = [arg for arg in args if arg.startswith('--user-data-dir=')]
    CORE.require(len(data_flags) == 1, 'ambiguous-user-data-dir')
    data_flag = data_flags[0].split('=', 1)[1]
    CORE.require(Path(data_flag).resolve(strict=True) == data, 'wrong-user-data-dir')
    for name, value in (('--user-data-dir', data_flag), ('--proxy-server', f'http://127.0.0.1:{proxy_port}'),
                        ('--proxy-bypass-list', '<-loopback>'), ('--remote-debugging-address', '127.0.0.1'),
                        ('--remote-debugging-port', '0'), ('--use-mock-keychain', None)):
        try:
            CORE.flag(args, name, value)
        except ValueError as error:
            raise ValueError(f'invalid-chromium-flag-{name.removeprefix("--")}') from error
    port_file = data / 'DevToolsActivePort'
    # Chromium can create this file mode 0644 inside the owner-only data directory.
    fd = os.open(port_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        CORE.require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                     and info.st_nlink == 1 and info.st_mode & 0o022 == 0, 'unsafe-devtools-port-file')
        port, websocket = endpoint(stream.read(129))
    listeners = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-a', '-iTCP:' + str(port),
                                         '-sTCP:LISTEN', '-Fpn'], text=True, timeout=5)
    CORE.require(listener_is_owned(listeners, process['pid'], port), 'devtools-listener-not-owned')
    CORE.require(CORE.read_private(lease_path, 16384) == lease_raw
                 and CORE.kernel_process(manager_pid, manager) == owner
                 and CORE.kernel_process(lease['pid'], browser) == process, 'live-custody-changed')
    return {'status': 'observed', 'candidateArchiveSHA256': candidate['sha256'],
            'candidateReceiptSHA256': CORE.sha(stage_raw), 'profileID': str(profile_id),
            'browserData': str(data), 'manager': owner, 'browser': process,
            'browserExecutableSHA256': CORE.sha(browser.read_bytes()),
            'leaseSHA256': CORE.sha(lease_raw), 'websocket': f'ws://127.0.0.1:{port}{websocket}',
            'browserRouteVerified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--archive-sha256', required=True, help='SHA-256 from the exact archive preflight')
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--profile', required=True, type=uuid.UUID)
    parser.add_argument('--manager-pid', required=True, type=int)
    parser.add_argument('--proxy-port', required=True, type=int)
    parser.add_argument('--receipt-name', required=True, choices=('first-launch', 'reopened'))
    parser.add_argument('--stopped-status', type=Path,
                        help='Verify exit using the existing launch receipt and an owned MCP profile_status result')
    args = parser.parse_args()
    if not 1 <= args.proxy_port <= 65535:
        parser.error('proxy port out of range')
    try:
        receipt = args.root / f'chromium-custody-{args.receipt_name}.json'
        if args.stopped_status is None:
            report = collect(args.candidate, args.archive_sha256, args.root, args.profile, args.manager_pid, args.proxy_port)
            CORE.write_new(receipt, report)
        else:
            data = args.root / 'Profiles' / str(args.profile).upper() / 'BrowserData'
            CORE.require(data.resolve(strict=True) == data, 'unsafe-fixture-directory')
            custody = CORE.load(receipt)
            CORE.require(custody['candidateArchiveSHA256'] == args.archive_sha256
                         and custody['candidateReceiptSHA256'] == CORE.sha(CORE.read_private(args.candidate, 16384))
                         and uuid.UUID(custody['profileID']) == args.profile, 'stop-custody-mismatch')
            candidate = CORE.load(args.candidate)
            manager = Path(candidate['app']) / 'Contents/MacOS/NeAntik'
            CORE.require(CORE.kernel_process(args.manager_pid, manager) == custody['manager']
                         and CORE.argv_for(args.manager_pid)[1:] == ['--neantik-mcp-stdio',
                             '--neantik-mcp-loopback-qa-v1', str(args.root), str(args.proxy_port)],
                         'stop-manager-custody-changed')
            report = observe_stop(custody, data, CORE.load(args.stopped_status))
            CORE.write_new(args.root / f'chromium-stop-{args.receipt_name}.json', report)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Chromium custody refused ({type(error).__name__}).\n')
    print('Owned Chromium observation captured in the private QA receipt.')


if __name__ == '__main__':
    main()
