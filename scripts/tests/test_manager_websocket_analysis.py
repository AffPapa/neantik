"""Modeled analyzer sensitivity, distinct from an actual headed measurement."""
import copy
import importlib.util
from pathlib import Path
import unittest
import tempfile
import json

SPEC = importlib.util.spec_from_file_location('manager_ws_analysis_test', Path(__file__).resolve().parents[1] / 'runtime-network/analyze-manager-websocket.py')
A = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(A)
H = 'a' * 64


def model():
    process = lambda pid, parent: dict(pid=pid, parentPID=parent, uid=501, startSeconds=100, startMicroseconds=1, cdhash='b' * 40)
    manager, browser, owner, direct_browser = process(10, 1), process(11, 10), process(12, 10), process(13, 10)
    release = dict(version='test', build=1, managerSHA256=H, runtime=dict(executableSHA256=H, frameworkSHA256=H))
    state = dict(version='test', build=1, managerPID=10, managerSHA256=H, candidateManifestSHA256=H, profiles=[dict(id='profile-a'), dict(id='profile-b')],
                 fixtureSHA256=H, websocketFixtureSHA256=H, websocketProbeSHA256=H)
    before = dict(phase='before-launch', at=1, manager=manager, managerSHA256=H, version='test', build=1, candidateManifestSHA256=H,
                  profileID='profile-a', directBaseline=dict(profileID='profile-b'), **{key: H for key in A.HASHES})
    relay = dict(profileID='profile-a', sessionGeneration='session-a', configurationSHA256=H, ownerPID=12, ownerUID=501,
                 ownerStartSeconds=100, ownerStartMicroseconds=1, runtimeExecutableSHA256=H, runtimeFrameworkSHA256=H)
    success = dict(before, phase='proxy-success', at=12, browser=browser, relayOwner=owner, relay=relay,
                   configurationSHA256=H, leaseSHA256=H, sessionGeneration='session-a', runtimeExecutableSHA256=H, runtimeFrameworkSHA256=H)
    direct = dict(before, phase='direct-control', at=24, browser=direct_browser, profileID='profile-b', relay=None,
                  sessionGeneration='session-b', runtimeExecutableSHA256=H, runtimeFrameworkSHA256=H)
    events = []
    for sample, start in ((success, 2), (direct, 14)):
        mode = sample['phase']; protected = mode == 'proxy-success'
        custody = dict(manager=manager, browser=sample['browser'], profileID=sample['profileID'], sessionGeneration=sample['sessionGeneration'],
                       peerChain=[owner] if protected else [direct_browser], socketTupleSHA256=H)
        if protected: custody['configurationSHA256'] = H
        peer = dict(route='proxy' if protected else 'direct', custody=custody)
        def event(kind, at, **extra): events.append(dict(kind=kind, at=start + at, mode=mode, **extra))
        event('ws-page', 0, peer=copy.deepcopy(peer))
        event('ws-control', 1, phase='initial', channelsCut=0)
        for phase, offset in [('initial', 2), ('blocked', 5), ('recovered', 8)]:
            if phase == 'blocked': event('ws-control', 4, phase='blocked', channelsCut=2 if protected else 0)
            if phase == 'recovered': event('ws-control', 7, phase='recovered', channelsCut=0)
            if protected and phase == 'blocked': event('ws-connect-refused', offset); continue
            key = mode + phase; event('ws-handshake', offset, phase=phase, eventID=key, peer=copy.deepcopy(peer))
            event('ws-echo', offset + .1, phase=phase, eventID=key)
            event('ws-closed', 4.1 if phase == 'initial' and protected else offset + .2, eventID=key)
        rows = [dict(phase=p, opened=p != 'blocked' or not protected, echoed=p != 'blocked' or not protected,
                     errored=p == 'blocked' and protected, closeCode=1006 if protected and p in ('initial', 'blocked') else 1000)
                for p in ('initial', 'blocked', 'recovered')]
        event('ws-result', 9, peer=copy.deepcopy(peer), result=dict(mode=mode, rows=rows, errors=[], remaining=0,
              held=dict(aborted=True, closeCode=1006) if protected else dict(stillOpen=True)))
    events.sort(key=lambda e: e['at'])
    cleanup = dict(at=26, ownedProcessesRemaining=0, ordinaryInstanceTouched=False,
                   browserExitObservations=[dict(profileID=p, launchCount=1, terminationReason=1, terminationStatus=0, logSHA256=H) for p in ('profile-a', 'profile-b')])
    receipts = {'ws-custody-before-launch.json': before, 'ws-custody-proxy-success.json': success,
                'ws-custody-direct-control.json': direct, 'ws-custody-cleanup.json': cleanup,
                'fixture-ledger.json': dict(events=events, serverThreadsDrained=True, managerExitCode=0,
                                           runtimeCleanup=dict(ownedRuntimeProcessesRemaining=0, signaledMainProcesses=0))}
    return receipts, release, state


class ManagerWebSocketAnalysisTests(unittest.TestCase):
    def test_public_release_reader_accepts_tracked_mode_and_refuses_links_or_nonobjects(self):
        with tempfile.TemporaryDirectory(prefix='neantik-ws-release-reader-') as root:
            file = Path(root) / 'release.json'; file.write_text(json.dumps({'version': 'public'})); file.chmod(0o644)
            self.assertEqual(A.load_release(file), {'version': 'public'})
            linked = Path(root) / 'linked'; linked.symlink_to(file)
            with self.assertRaises(OSError): A.load_release(linked)
            file.write_text('[]')
            with self.assertRaises(ValueError): A.load_release(file)
            with self.assertRaises(ValueError): A.load_release(Path(root))

    def test_complete_modeled_evidence_passes_only_scoped_WS(self):
        result = A.qualify(*model()); self.assertFalse(result['WSSQualified']); self.assertFalse(result['releaseGate'])
        self.assertEqual(result['actualOriginHandshakes'], 5)

    def test_capture_modes_cannot_be_combined_or_mislabeled(self):
        for args in [dict(manager_websocket=True, manager_webrtc=True), dict(manager_websocket=True, physical_tcp=True)]:
            with self.assertRaises(ValueError): A.C.CORE.capture({}, Path('/not-used'), 'proxy-success', **args)
        with self.assertRaises(ValueError): A.C.capture({}, Path('/not-used'), 'dns-refused')
        with self.assertRaises(ValueError): A.C.CORE.capture({'websocketFixture': {'mode': 'wrong'}}, Path('/not-used'), 'proxy-success', manager_websocket=True)

    def test_each_missing_or_contradictory_surface_refuses(self):
        def event(r, kind): return next(e for e in r['fixture-ledger.json']['events'] if e['kind'] == kind)
        changes = [
            lambda r, v, s: r['fixture-ledger.json'].update(serverThreadsDrained=False),
            lambda r, v, s: r['fixture-ledger.json']['runtimeCleanup'].update(signaledMainProcesses=1),
            lambda r, v, s: r['ws-custody-cleanup.json'].update(ownedProcessesRemaining=1),
            lambda r, v, s: r['ws-custody-cleanup.json']['browserExitObservations'][0].update(terminationReason=2),
            lambda r, v, s: r['ws-custody-cleanup.json']['browserExitObservations'][0].update(terminationStatus=15),
            lambda r, v, s: r['ws-custody-cleanup.json']['browserExitObservations'].pop(),
            lambda r, v, s: v.update(managerSHA256='c' * 64),
            lambda r, v, s: s.update(candidateManifestSHA256='c' * 64),
            lambda r, v, s: r['ws-custody-proxy-success.json'].update(websocketProbeSHA256='c' * 64),
            lambda r, v, s: r['ws-custody-proxy-success.json'].update(runtimeExecutableSHA256='c' * 64),
            lambda r, v, s: r['ws-custody-proxy-success.json']['relay'].update(configurationSHA256='c' * 64),
            lambda r, v, s: r['ws-custody-direct-control.json'].update(relay={}),
            lambda r, v, s: event(r, 'ws-handshake')['peer'].update(route='direct'),
            lambda r, v, s: event(r, 'ws-handshake')['peer']['custody'].update(sessionGeneration='other-session'),
            lambda r, v, s: event(r, 'ws-handshake')['peer']['custody']['peerChain'][0].update(startMicroseconds=2),
            lambda r, v, s: event(r, 'ws-handshake').update(at=99),
            lambda r, v, s: event(r, 'ws-echo').update(eventID='missing'),
            lambda r, v, s: event(r, 'ws-closed').update(eventID='missing'),
            lambda r, v, s: event(r, 'ws-connect-refused').update(kind='missing'),
            lambda r, v, s: event(r, 'ws-result')['result'].update(errors=['timeout']),
            lambda r, v, s: event(r, 'ws-result')['result'].update(remaining=1),
            lambda r, v, s: event(r, 'ws-result')['result']['rows'][1].update(opened=True),
            lambda r, v, s: event(r, 'ws-result')['result']['held'].update(aborted=False),
            lambda r, v, s: event(r, 'ws-result')['result']['rows'][0].update(closeCode=1000),
        ]
        for index, mutate in enumerate(changes):
            receipts, release, state = model(); mutate(receipts, release, state)
            with self.subTest(index=index), self.assertRaises(ValueError): A.qualify(receipts, release, state)


if __name__ == '__main__': unittest.main()
