#!/usr/bin/env python3
"""Live state and normal-exit custody for the distinct owned WS fixture."""
import argparse
import importlib.util
import os
from pathlib import Path
import stat
import uuid

SPEC = importlib.util.spec_from_file_location('manager_ws_custody_core', Path(__file__).with_name('collect-manager-webrtc.py'))
W = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(W)
CORE = W.CORE
PHASES = ('before-launch', 'proxy-success', 'direct-control')


def owned_state(path):
    state = CORE.load(path); root = Path(state['root']); info = root.lstat()
    CORE.require(root.parent == Path('/private/tmp') and root.name == 'neantik-update-audit-' + str(uuid.UUID(root.name.removeprefix('neantik-update-audit-')))
                 and stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077, 'unsafe-ws-root')
    CORE.require(state['data'] == str(root / 'manager-data') and state['manifest'] == str(root / 'candidate-manifest.json')
                 and state['websocketFixture']['mode'] == 'manager-websocket' and len(state['profiles']) == 2
                 and [p['name'] for p in state['profiles']] == ['QA route proxy', 'QA route direct'], 'wrong-ws-state')
    for profile in state['profiles']: CORE.require(str(uuid.UUID(profile['id'])).lower() == profile['id'].lower(), 'invalid-ws-profile')
    return state, root


def capture(state, root, phase):
    CORE.require(phase in PHASES, 'wrong-ws-phase')
    result = CORE.capture(state, root, phase, manager_websocket=True)
    result['websocketCollectorSHA256'] = CORE.sha(Path(__file__).read_bytes())
    result['peerCollectorSHA256'] = CORE.sha(Path(__file__).with_name('collect-manager-webrtc.py').read_bytes())
    if phase != 'before-launch':
        command = CORE.argv_for(result['browser']['pid'])
        CORE.require(not any(arg.startswith('--ignore-certificate-errors-spki-list') for arg in command), 'ws-trust-override')
        manifest = CORE.load(root / 'candidate-manifest.json')
        for key in ('runtimeExecutable', 'runtimeFramework'):
            record = manifest['criticalFiles'][key]; actual = CORE.sha((Path(state['app']) / record['bundlePath']).read_bytes())
            CORE.require(actual == record['sha256'], 'ws-runtime-changed'); result[key + 'SHA256'] = actual
    return result


def cleanup(state, root, receipts):
    samples = [CORE.load(receipts / ('ws-custody-' + phase + '.json')) for phase in PHASES]
    pids = {p['pid'] for sample in samples for key in ('manager', 'browser', 'relayOwner') if (p := sample.get(key))}
    inventory = CORE.subprocess.check_output(['/bin/ps', '-axo', 'pid=,uid=,command='], text=True, timeout=5)
    remaining = 0
    for line in inventory.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3: continue
        pid, uid, command = parts
        if int(pid) in pids or (int(uid) == os.getuid() and any(x in command for x in (str(root), str(root).replace('/private/tmp/', '/tmp/')))): remaining += 1
    manifest_raw = CORE.read_private(root / 'candidate-manifest.json'); manifest = CORE.json.loads(manifest_raw)
    CORE.require(CORE.sha(manifest_raw) == state['candidateManifestSHA256'], 'ws-manifest-changed')
    record = manifest['criticalFiles']['runtimeInfoPlist']; info_raw = (Path(state['app']) / record['bundlePath']).read_bytes()
    CORE.require(CORE.sha(info_raw) == record['sha256'], 'ws-runtime-info-changed')
    import plistlib
    version = plistlib.loads(info_raw)['CFBundleShortVersionString']; exits = []
    for profile in state['profiles']:
        raw = CORE.read_private(root / 'manager-data/Logs' / (str(uuid.UUID(profile['id'])).upper() + '.manager.log'), 65536)
        exits.append(dict(profileID=profile['id'].lower(), logSHA256=CORE.sha(raw), **W.exit_observation(raw.decode('utf-8'), version)))
    return dict(schemaVersion=1, at=W.time.monotonic(), ownedProcessesRemaining=remaining, browserExitObservations=exits,
                collectorSHA256=CORE.sha(Path(__file__).read_bytes()), ordinaryInstanceTouched=False, gracefulCloseQualified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--phase', choices=(*PHASES, 'cleanup'), required=True); args = parser.parse_args()
    try:
        state, root = owned_state(args.state); receipts = CORE.receipt_directory(args.state)
        value = cleanup(state, root, receipts) if args.phase == 'cleanup' else capture(state, root, args.phase)
        CORE.write_new(receipts / ('ws-custody-' + args.phase + '.json'), value)
    except (KeyError, TypeError, ValueError, OSError, CORE.subprocess.SubprocessError): parser.exit(1, 'Owned WS custody refused.\n')
    print('{"result":"captured","browserQualification":false}')


if __name__ == '__main__': main()
