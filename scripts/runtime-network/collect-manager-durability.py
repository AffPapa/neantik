#!/usr/bin/env python3
"""Current signed Direct session custody around an owned delayed close."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid

SPEC = importlib.util.spec_from_file_location('durability_custody_core', Path(__file__).with_name('collect-manager-dns.py'))
CORE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(CORE)
STAGES = ('written', 'pending', 'deadline', 'cancelled', 'read')


def owned_state(path):
    state = CORE.load(path); root = Path(state['root']); info = root.lstat()
    CORE.require(root.parent == Path('/private/tmp') and root.name == 'neantik-update-audit-' + str(uuid.UUID(root.name.removeprefix('neantik-update-audit-')))
                 and stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077, 'unsafe-durability-root')
    CORE.require(state['data'] == str(root / 'manager-data') and state['manifest'] == str(root / 'candidate-manifest.json')
                 and state['durabilityFixture']['mode'] == 'manager-data-durability' and len(state['profiles']) == 2
                 and [p['name'] for p in state['profiles']] == ['QA route proxy', 'QA route direct'], 'wrong-durability-state')
    for profile in state['profiles']: CORE.require(str(uuid.UUID(profile['id'])).lower() == profile['id'].lower(), 'invalid-durability-profile')
    return state, root


def capture(state, root, stage):
    CORE.require(stage in STAGES, 'wrong-durability-stage')
    result = CORE.capture(state, root, 'direct-control', manager_durability=True)
    result['durabilityStage'] = stage
    result['durabilityCollectorSHA256'] = CORE.sha(Path(__file__).read_bytes())
    result['peerCollectorSHA256'] = CORE.sha(Path(__file__).with_name('collect-manager-webrtc.py').read_bytes())
    command = CORE.argv_for(result['browser']['pid'])
    CORE.require(not any(arg.startswith('--ignore-certificate-errors-spki-list') for arg in command), 'durability-trust-override')
    manifest = CORE.load(root / 'candidate-manifest.json')
    for key in ('runtimeExecutable', 'runtimeFramework'):
        record = manifest['criticalFiles'][key]; actual = CORE.sha((Path(state['app']) / record['bundlePath']).read_bytes())
        CORE.require(actual == record['sha256'], 'durability-runtime-changed'); result[key + 'SHA256'] = actual
    return result


def normal_exits(text, runtime_version):
    launches = re.findall(r'^\S+ browser_launch version=([^\r\n]+)$', text, re.M)
    exits = re.findall(r'^\S+ browser_exit reason=([0-9]+) status=(-?[0-9]+)$', text, re.M)
    CORE.require(launches == [runtime_version] * 2 and len(exits) == 2, 'durability-exits-missing-or-ambiguous')
    return dict(launchCount=2, exits=[dict(reason=int(reason), status=int(status)) for reason, status in exits])


def cleanup(state, root, receipts):
    samples = [CORE.load(receipts / ('durability-custody-' + stage + '.json')) for stage in STAGES]
    pids = {sample[key]['pid'] for sample in samples for key in ('manager', 'browser')}
    rows = CORE.subprocess.check_output(['/bin/ps', '-axo', 'pid=,uid=,command='], text=True, timeout=5); remaining = 0
    for line in rows.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3: continue
        pid, uid, command = parts
        if int(pid) in pids or (int(uid) == os.getuid() and any(value in command for value in (str(root), str(root).replace('/private/tmp/', '/tmp/')))): remaining += 1
    manifest_raw = CORE.read_private(root / 'candidate-manifest.json'); manifest = json.loads(manifest_raw)
    CORE.require(CORE.sha(manifest_raw) == state['candidateManifestSHA256'], 'durability-manifest-changed')
    record = manifest['criticalFiles']['runtimeInfoPlist']; info = (Path(state['app']) / record['bundlePath']).read_bytes()
    CORE.require(CORE.sha(info) == record['sha256'], 'durability-runtime-info-changed')
    import plistlib
    profile = state['profiles'][1]; log = CORE.read_private(root / 'manager-data/Logs' / (str(uuid.UUID(profile['id'])).upper() + '.manager.log'), 65536)
    return dict(schemaVersion=1, at=time.monotonic(), ownedProcessesRemaining=remaining, ordinaryInstanceTouched=False,
                browserExits=normal_exits(log.decode('utf-8'), plistlib.loads(info)['CFBundleShortVersionString']),
                logSHA256=CORE.sha(log), collectorSHA256=CORE.sha(Path(__file__).read_bytes()), crashRecoveryQualified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--stage', choices=(*STAGES, 'cleanup'), required=True); args = parser.parse_args()
    try:
        state, root = owned_state(args.state); receipts = CORE.receipt_directory(args.state)
        value = cleanup(state, root, receipts) if args.stage == 'cleanup' else capture(state, root, args.stage)
        CORE.write_new(receipts / ('durability-custody-' + args.stage + '.json'), value)
    except (KeyError, TypeError, ValueError, OSError, CORE.subprocess.SubprocessError): parser.exit(1, 'Own durability custody refused.\n')
    print('{"stage":"captured","crashRecoveryQualified":false}')


if __name__ == '__main__': main()
