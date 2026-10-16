#!/usr/bin/env python3
"""Socket custody for the explicit DEBUG background fixture, not shipping GUI.

The launch manager has exited. The retained lease and pipe-delivered process
generations bind its still-running owned Chromium and relay; no broad UID or
Apple-process authority is admitted. Raw argv/addresses remain in memory.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

SPEC = importlib.util.spec_from_file_location('background_kernel_custody', Path(__file__).with_name('collect-manager-dns.py'))
KERNEL = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(KERNEL)


def require(value, reason):
    if not value: raise ValueError(reason)


def matches_generation(observed, expected):
    return (type(observed.get('pid')) is int and observed['pid'] > 1
            and observed.get('uid') == expected.get('userID') == os.getuid()
            and observed.get('startSeconds') == expected.get('seconds')
            and observed.get('startMicroseconds') == expected.get('microseconds'))


def validate_binding(receipt, lease, browser, owner):
    """Pure rejection controls; the caller must supply genuine kernel reads."""
    original = receipt['quitSnapshot']['lease']
    require(lease.get('schemaVersion') == 3 and lease.get('phase') == 'running', 'lease-not-running')
    # createdAt has different JSON date encodings on disk and in the private
    # pipe. Every field is pinned again by the baseline raw lease hash below.
    require(set(lease) == set(original) and all(lease[k] == original[k] for k in lease if k != 'createdAt'), 'lease-binding-changed')
    relay = lease['relay']
    require(receipt['browserPID'] == lease['pid'] == browser['pid']
            and receipt['ownerPID'] == relay['ownerPID'] == owner['pid'], 'wrong-live-process')
    require(matches_generation(browser, receipt['quitSnapshot']['browser'])
            and matches_generation(owner, receipt['quitSnapshot']['owner']), 'process-generation-changed')
    require(relay['ownerUID'] == owner['uid'] and relay['ownerStartSeconds'] == owner['startSeconds']
            and relay['ownerStartMicroseconds'] == owner['startMicroseconds'], 'relay-generation-changed')
    require(relay['sessionGeneration'] == lease['ownerToken']
            and relay['loopbackPort'] == receipt['relayPort'], 'session-changed')
    require(relay['runtimeExecutableSHA256'] == receipt['runtimeExecutableSHA256']
            and relay['runtimeFrameworkSHA256'] == receipt['runtimeFrameworkSHA256'], 'runtime-binding-changed')


class BackgroundPeerCustody:
    def __init__(self, root, app, receipt):
        self.root, self.app, self.receipt = Path(root).resolve(), Path(app).resolve(), receipt
        require(self.root.parent == Path('/private/tmp')
                and self.root.name.startswith('neantik-relay-owner-qualification-')
                and self.root.stat().st_uid == os.getuid()
                and self.root.stat().st_mode & 0o777 == 0o700, 'owned-background-root-required')
        relay = receipt['quitSnapshot']['lease']['relay']
        profile = str(uuid.UUID(relay['profileID'])).upper()
        self.lock = self.root / 'Profiles' / profile / '.neantik.lock'
        self.lease_hash = KERNEL.sha(KERNEL.read_private(self.lock))
        self.manager_exe = self.app / 'Contents/MacOS/NeAntik'
        self.browser_exe = self.app / 'Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser'
        self.browser, self.owner = self.inspect()
        args = KERNEL.argv_for(self.browser['pid'])
        KERNEL.flag(args, '--use-mock-keychain', None)
        KERNEL.flag(args, '--user-data-dir', str(self.root / 'Profiles' / profile / 'BrowserData'))
        KERNEL.flag(args, '--proxy-server', 'socks5://127.0.0.1:' + str(receipt['relayPort']))
        KERNEL.flag(args, '--proxy-bypass-list', '<-loopback>')
        KERNEL.flag(args, '--remote-debugging-address', '127.0.0.1')
        KERNEL.flag(args, '--remote-debugging-port', '0')
        KERNEL.flag(args, '--net-log-capture-mode', 'Default')
        require(not any(x.split('=', 1)[0] in ('--disable-background-networking', '--disable-component-update',
                    '--disable-sync', '--disable-extensions', '--headless') for x in args), 'suppressed-background-launch')
        require(KERNEL.argv_for(self.owner['pid']) == [str(self.manager_exe), '--neantik-proxy-relay-owner-v1'], 'wrong-owner-entry')

    def inspect(self):
        raw = KERNEL.read_private(self.lock)
        require(KERNEL.sha(raw) == self.lease_hash, 'lease-file-changed')
        browser = KERNEL.kernel_process(self.receipt['browserPID'], self.browser_exe)
        owner = KERNEL.kernel_process(self.receipt['ownerPID'], self.manager_exe)
        validate_binding(self.receipt, json.loads(raw), browser, owner)
        return browser, owner

    def capture(self, channel):
        browser, owner = self.inspect()
        require(browser == self.browser and owner == self.owner, 'live-process-custody-changed')
        client, server = channel.getpeername(), channel.getsockname()
        require(client[0] == server[0] == '127.0.0.1', 'non-loopback-peer')
        edge = f'127.0.0.1:{client[1]}->127.0.0.1:{server[1]}'
        result = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(owner['pid']), '-nP',
                                 '-iTCP@127.0.0.1:' + str(server[1]), '-Fpn'],
                                capture_output=True, text=True, timeout=4)
        require(result.returncode == 0 and KERNEL.socket_owner(result.stdout, edge) == owner['pid'], 'peer-not-owned-relay')
        require(self.inspect() == (browser, owner), 'process-changed-during-peer-read')
        return dict(leaseSHA256=self.lease_hash, sessionGeneration=self.receipt['quitSnapshot']['lease']['ownerToken'],
                    configurationSHA256=self.receipt['quitSnapshot']['lease']['relay']['configurationSHA256'],
                    browser=browser, relayOwner=owner, socketTupleSHA256=hashlib.sha256(edge.encode()).hexdigest())
