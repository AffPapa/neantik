#!/usr/bin/env python3
"""Bounded live custody for the physical TCP fixture; no DNS-route verdict."""
import argparse
import importlib.util
from pathlib import Path
import os
import stat
import time
import uuid

SPEC = importlib.util.spec_from_file_location('tcp_kernel_custody_core', Path(__file__).with_name('collect-manager-dns.py'))
CORE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(CORE)
PHASES = ('before-launch', 'proxy-success', 'listener-refused', 'direct-control', 'proxy-recovered')


def owned_state(path):
    state = CORE.load(path)
    root = Path(state['root'])
    CORE.require(root.parent == Path('/private/tmp') and root.name.startswith('neantik-update-audit-')
                 and str(uuid.UUID(root.name.removeprefix('neantik-update-audit-'))) == root.name.removeprefix('neantik-update-audit-'), 'owned-root-required')
    info = root.lstat()
    CORE.require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077, 'unsafe-owned-root')
    CORE.require(state['data'] == str(root / 'manager-data') and state['manifest'] == str(root / 'candidate-manifest.json')
                 and state['tcpFixture']['mode'] == 'manager-physical-tcp' and len(state['profiles']) == 2
                 and [p['name'] for p in state['profiles']] == ['QA route proxy', 'QA route direct'], 'wrong-tcp-fixture-state')
    for profile in state['profiles']:
        CORE.require(str(uuid.UUID(profile['id'])).lower() == profile['id'].lower(), 'invalid-profile-id')
    return state, root


def capture(state, root, phase):
    CORE.require(phase in PHASES, 'wrong-tcp-phase')
    value = CORE.capture(state, root, phase, physical_tcp=True)
    value['tcpCollectorSHA256'] = CORE.sha(Path(__file__).read_bytes())
    return value


def cleanup(state, root, receipts):
    # Existing cleanup only needs the recorded PID set. Read these TCP names
    # explicitly; do not fabricate or rename historical DNS receipts.
    samples = [CORE.load(receipts / ('tcp-custody-' + phase + '.json')) for phase in PHASES]
    pids = {p['pid'] for s in samples for key in ('manager', 'browser', 'relayOwner') if (p := s.get(key))}
    inventory = CORE.subprocess.check_output(['/bin/ps', '-axo', 'pid=,uid=,command='], text=True, timeout=5)
    remaining = 0
    for line in inventory.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3: continue
        pid, uid, command = parts
        if int(pid) in pids or (int(uid) == os.getuid() and
                (str(root) in command or str(root).replace('/private/tmp/', '/tmp/') in command)):
            remaining += 1
    return dict(schemaVersion=1, at=time.monotonic(), ownedProcessesRemaining=remaining,
                collectorSHA256=CORE.sha(Path(__file__).read_bytes()), ordinaryInstanceTouched=False,
                gracefulCloseQualified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--phase', required=True, choices=(*PHASES, 'cleanup'))
    args = parser.parse_args()
    try:
        state, root = owned_state(args.state); output = CORE.receipt_directory(args.state)
        value = cleanup(state, root, output) if args.phase == 'cleanup' else capture(state, root, args.phase)
        CORE.write_new(output / ('tcp-custody-' + args.phase + '.json'), value)
    except (KeyError, TypeError, ValueError, OSError, CORE.subprocess.SubprocessError):
        parser.exit(1, 'Owned TCP custody refused.\n')
    print('{"result":"captured","browserQualification":false}')


if __name__ == '__main__': main()
