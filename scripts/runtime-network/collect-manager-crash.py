#!/usr/bin/env python3
"""Custody-bound own main SIGKILL and recovery; never signal a process group."""
import argparse
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import time
import uuid

SPEC = importlib.util.spec_from_file_location('crash_custody_core', Path(__file__).with_name('collect-manager-dns.py'))
CORE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(CORE)
LIVE_STAGES = ('baseline', 'mutate', 'read')


def owned_state(path):
    state = CORE.load(path); root = Path(state['root']); info = root.lstat()
    CORE.require(root.parent == Path('/private/tmp') and root.name == 'neantik-update-audit-' + str(uuid.UUID(root.name.removeprefix('neantik-update-audit-')))
                 and stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077, 'unsafe-crash-root')
    CORE.require(state['data'] == str(root / 'manager-data') and state['manifest'] == str(root / 'candidate-manifest.json')
                 and state['crashFixture']['mode'] == 'manager-main-crash' and len(state['profiles']) == 2
                 and [p['name'] for p in state['profiles']] == ['QA route proxy', 'QA route direct'], 'wrong-crash-state')
    for profile in state['profiles']: CORE.require(str(uuid.UUID(profile['id'])).lower() == profile['id'].lower(), 'invalid-crash-profile')
    return state, root


def capture(state, root, stage):
    CORE.require(stage in LIVE_STAGES, 'wrong-crash-stage')
    value = CORE.capture(state, root, 'direct-control', manager_crash=True)
    CORE.require(value['peerCollectorSHA256'] == CORE.sha(Path(__file__).with_name('collect-manager-webrtc.py').read_bytes()), 'crash-peer-source-changed')
    value.update(crashStage=stage, crashCollectorSHA256=CORE.sha(Path(__file__).read_bytes()))
    args = CORE.argv_for(value['browser']['pid'])
    CORE.require(not any(a.startswith('--ignore-certificate-errors-spki-list') for a in args), 'crash-trust-override')
    manifest = CORE.load(root / 'candidate-manifest.json')
    for key in ('runtimeExecutable', 'runtimeFramework'):
        item = manifest['criticalFiles'][key]; actual = CORE.sha((Path(state['app']) / item['bundlePath']).read_bytes())
        CORE.require(actual == item['sha256'], 'crash-runtime-changed'); value[key + 'SHA256'] = actual
    value['runtimeProcesses'] = owned_descendants(value['browser'], Path(state['app']) / 'Contents/Resources/NeAntik Browser.app')
    return value


def validate_target(previous, current, events):
    """A stored PID alone or page intent cannot authorize the destructive step."""
    for key in ('manager', 'browser', 'profileID', 'metadataIdentitySHA256', 'sessionGeneration', 'leaseSHA256',
                'revision', 'lastLaunchedAt', 'updatedAt', 'managerSHA256', 'candidateManifestSHA256',
                'runtimeExecutableSHA256', 'runtimeFrameworkSHA256', 'crashFixtureSHA256', 'crashProbeSHA256', 'crashCollectorSHA256',
                'fixtureSHA256', 'collectorSHA256', 'peerCollectorSHA256'):
        CORE.require(previous[key] == current[key], 'crash-target-changed')
    CORE.require(previous['crashStage'] == current['crashStage'] == 'mutate' and current['phase'] == 'direct-control'
                 and current.get('relay') is None, 'not-own-direct-crash-target')
    results = [e for e in events if e.get('kind') == 'crash-result' and e.get('phase') == 'mutate']
    CORE.require(len(results) == 1, 'crash-write-receipt-missing')
    result = results[0]
    CORE.require(result['strictCompleted'] is True and result['abortedAfterRequestSuccess'] is True and result['abortedValueAbsent'] is True
                 and result['baselineIntact'] is True and result['strictIDBRetained'] is True and result['wrote'] is True
                 and result['peer']['manager'] == current['manager'] and result['peer']['browser'] == current['browser']
                 and result['peer']['profileID'] == current['profileID'] and result['peer']['sessionGeneration'] == current['sessionGeneration']
                 and 0 <= current['at'] - result['at'] <= 120, 'crash-write-or-peer-not-qualified')


def owned_descendants(browser, bundle):
    rows = CORE.subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,uid=,comm='], text=True, timeout=5)
    parsed = [row.strip().split(None, 3) for row in rows.splitlines()]
    found = [browser]; paths = [str(bundle / 'Contents/MacOS/NeAntik Browser')]
    known = {browser['pid']}
    for _ in range(16):
        children = [int(p[0]) for p in parsed if len(p) == 4 and p[0].isdigit() and p[1].isdigit()
                    and int(p[1]) in known and int(p[0]) not in known]
        if not children: break
        CORE.require(len(known) + len(children) <= 128, 'crash-descendant-bound')
        for pid in children:
            path = CORE.process_path(pid)
            CORE.require(path.is_relative_to(bundle.resolve()), 'foreign-crash-descendant')
            item = CORE.kernel_process(pid, path); CORE.require(item['parentPID'] in known, 'crash-child-reparented')
            found.append(item); paths.append(str(path)); known.add(pid)
    else: raise ValueError('crash-descendant-depth')
    CORE.require(all(CORE.kernel_process(item['pid'], Path(path)) == item for item, path in zip(found, paths)), 'crash-tree-changed')
    return [dict(identity=item, executable=path) for item, path in zip(found, paths)]


def generation_absent(identity):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True); info = CORE.BSDInfo()
    ctypes.set_errno(0); count = library.proc_pidinfo(identity['pid'], 3, 0, ctypes.byref(info), 136)
    if count == 0:
        CORE.require(ctypes.get_errno() == errno.ESRCH, 'crash-generation-unknown'); return True
    CORE.require(count == 136 and info.pid == identity['pid'] and info.seconds > 0, 'crash-generation-unknown')
    return (info.seconds, info.microseconds) != (identity['startSeconds'], identity['startMicroseconds'])


def signal_own_main(state, root, directory):
    CORE.require(not (directory / 'crash-intent.json').exists() and not (directory / 'crash-signal.json').exists(), 'crash-already-attempted')
    previous = CORE.load(directory / 'crash-custody-mutate.json'); current = capture(state, root, 'mutate')
    validate_target(previous, current, CORE.load(root / 'observations.json'))
    bundle = Path(state['app']) / 'Contents/Resources/NeAntik Browser.app'
    tree = current['runtimeProcesses']
    intent = dict(at=time.monotonic(), signal=signal.SIGKILL, target=current['browser'], manager=current['manager'],
                  custody=current, descendants=tree, collectorSHA256=CORE.sha(Path(__file__).read_bytes()))
    CORE.write_new(directory / 'crash-intent.json', intent)
    # Recheck exact generation/code and unchanged private lease after recording
    # intent; never authorize a broad kill from stale ps substrings.
    lock = root / 'manager-data/Profiles' / state['profiles'][1]['id'] / '.neantik.lock'
    CORE.require(CORE.kernel_process(current['browser']['pid'], bundle / 'Contents/MacOS/NeAntik Browser') == current['browser']
                 and CORE.sha(CORE.read_private(lock)) == current['leaseSHA256'], 'crash-final-custody-changed')
    os.kill(current['browser']['pid'], signal.SIGKILL)
    return dict(at=time.monotonic(), signal=9, issued=True, target=current['browser'], processGroupSignaled=False,
                ordinaryInstanceTouched=False, collectorSHA256=intent['collectorSHA256'])


def no_open_data_files(root, data):
    CORE.require(data.is_relative_to(root) and data != root, 'crash-data-outside-root')
    for directory in (data, *data.parents):
        info = directory.lstat()
        CORE.require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                     and os.access(directory, os.R_OK | os.X_OK), 'crash-data-directory-unsafe-or-unreadable')
        if directory == root: break
    observed = CORE.subprocess.run(['/usr/sbin/lsof', '-nP', '+D', str(data), '-Fp'], capture_output=True, text=True, timeout=10)
    CORE.require(observed.returncode == 1 and not observed.stdout and not observed.stderr, 'crash-data-still-open-or-unknown')


def after_crash(state, root, directory):
    intent = CORE.load(directory / 'crash-intent.json'); issued = CORE.load(directory / 'crash-signal.json')
    CORE.require(issued['issued'] is True and issued['signal'] == 9 and issued['target'] == intent['target'], 'crash-signal-not-proven')
    manager = CORE.kernel_process(state['managerPID'], Path(state['executable']))
    CORE.require(manager == intent['manager'], 'crash-manager-changed')
    profile = state['profiles'][1]; data = root / 'manager-data/Profiles' / profile['id'] / 'BrowserData'
    CORE.require(all(generation_absent(item['identity']) for item in intent['descendants']), 'crash-descendants-still-live')
    CORE.require(not (data.parent / '.neantik.lock').exists(), 'crash-lease-not-retired')
    no_open_data_files(root, data)
    log = CORE.read_private(root / 'manager-data/Logs' / (profile['id'] + '.manager.log'), 65536).decode()
    CORE.require(re.findall(r'browser_exit reason=([0-9]+) status=(-?[0-9]+)', log) == [('1','0'),('2','9')], 'crash-native-exit-not-proven')
    return dict(at=time.monotonic(), manager=manager, signal=9, mainGenerationAbsent=True, capturedDescendantsAbsent=True,
                capturedDescendantCount=len(intent['descendants']), leaseRetired=True, dataOpenFiles=0,
                observedExits=[dict(reason=1,status=0),dict(reason=2,status=9)], collectorSHA256=CORE.sha(Path(__file__).read_bytes()))


def cleanup(state, root, directory):
    samples = [CORE.load(directory / ('crash-custody-' + stage + '.json')) for stage in LIVE_STAGES]
    CORE.require(all(generation_absent(s['manager']) and all(generation_absent(p['identity']) for p in s['runtimeProcesses']) for s in samples),
                 'crash-cleanup-live-generation')
    rows = CORE.subprocess.check_output(['/bin/ps', '-axo', 'pid=,uid=,command='], text=True, timeout=5)
    remaining = sum(str(root) in row or str(root).replace('/private/tmp/', '/tmp/') in row for row in rows.splitlines())
    CORE.require(remaining == 0, 'crash-owned-process-remains')
    profile = state['profiles'][1]
    log = CORE.read_private(root / 'manager-data/Logs' / (profile['id'] + '.manager.log'), 65536)
    expected = [dict(reason=1,status=0),dict(reason=2,status=9),dict(reason=1,status=0)]
    exits = [dict(reason=int(reason),status=int(status)) for reason,status in re.findall(r'browser_exit reason=([0-9]+) status=(-?[0-9]+)',log.decode())]
    CORE.require(exits == expected and not (root / 'manager-data/Profiles' / profile['id'] / '.neantik.lock').exists(), 'crash-exit-cleanup-incomplete')
    return dict(at=time.monotonic(), ownedProcessesRemaining=0, logSHA256=CORE.sha(log), observedExits=exits,
                capturedGenerationsAbsent=True, leaseAbsent=True, ordinaryInstanceTouched=False, collectorSHA256=CORE.sha(Path(__file__).read_bytes()))


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--stage', choices=(*LIVE_STAGES, 'signal', 'after-crash', 'cleanup'), required=True); args = parser.parse_args()
    try:
        state, root = owned_state(args.state); directory = CORE.receipt_directory(args.state)
        if args.stage == 'signal': value = signal_own_main(state, root, directory); name = 'crash-signal.json'
        elif args.stage == 'after-crash': value = after_crash(state, root, directory); name = 'crash-after.json'
        elif args.stage == 'cleanup': value = cleanup(state, root, directory); name = 'crash-cleanup.json'
        else: value = capture(state, root, args.stage); name = 'crash-custody-' + args.stage + '.json'
        CORE.write_new(directory / name, value)
    except (ValueError, OSError, KeyError, TypeError, CORE.subprocess.SubprocessError): parser.exit(1, 'Own main-crash custody refused.\n')
    print(json.dumps(dict(stage=args.stage, captured=True, powerLossQualified=False)))


if __name__ == '__main__': main()
