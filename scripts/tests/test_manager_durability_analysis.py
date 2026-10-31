"""Strict modeled sensitivity before any native delayed-close observation."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('durability_analysis_test', Path(__file__).resolve().parents[1] / 'runtime-network/analyze-manager-durability.py')
A = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(A)
H = 'a' * 64


def model():
    process = lambda pid, parent: dict(pid=pid, parentPID=parent, uid=501, startSeconds=100, startMicroseconds=1, cdhash='b' * 40)
    manager, browser, next_browser = process(10, 1), process(11, 10), process(12, 10)
    release = dict(version='test', build=1, managerSHA256=H, runtime=dict(executableSHA256=H, frameworkSHA256=H))
    state = dict(managerPID=10, managerSHA256=H, candidateManifestSHA256=H, profiles=[dict(id='unused'), dict(id='own')], version='test', build=1,
                 fixtureSHA256=H, durabilityFixtureSHA256=H, durabilityProbeSHA256=H)
    samples = []
    for stage, at in zip(A.C.STAGES, (3, 4, 13, 14, 18)):
        last = stage == 'read'
        samples.append(dict(phase='direct-control', durabilityStage=stage, at=at, manager=manager, browser=next_browser if last else browser,
            managerSHA256=H, version='test', build=1, profileID='own', metadataIdentitySHA256=H, candidateManifestSHA256=H, relay=None,
            runtimeExecutableSHA256=H, runtimeFrameworkSHA256=H, sessionGeneration='next' if last else 'first', leaseSHA256=H,
            revision=2 if last else 1, lastLaunchedAt='next' if last else 'first', updatedAt='next' if last else 'first', **{k: H for k in A.HASHES}))
    events = []
    for sample, phase, low in ((samples[0], 'write', 1), (samples[-1], 'read', 16)):
        peer = dict(manager=manager, browser=sample['browser'], profileID='own', sessionGeneration=sample['sessionGeneration'], peerChain=[sample['browser']], socketTupleSHA256=H)
        events.append(dict(kind='durability-page', phase=phase, at=low, peer=copy.deepcopy(peer)))
        events.append(dict(kind='durability-result', phase=phase, at=low + 1, peer=copy.deepcopy(peer), allPersistentValuesMatch=True,
                           freshBeforeWrite=phase == 'write', sessionStorageFresh=phase == 'read', wrote=phase == 'write', strictIDB=phase == 'write'))
    ui = dict(source='native-cua-operator-reduction', managerPID=10, profileID='own', firstBrowserPID=11, readBrowserPID=12, **{k: True for k in A.UI_FLAGS})
    receipts = {'durability-ui.json': ui, **{'durability-custody-' + stage + '.json': sample for stage, sample in zip(A.C.STAGES, samples)},
        'durability-custody-cleanup.json': dict(at=20, ownedProcessesRemaining=0, ordinaryInstanceTouched=False, logSHA256=H,
                                              browserExits=dict(launchCount=2, exits=[dict(reason=1, status=0)] * 2)),
        'fixture-ledger.json': dict(events=events, serverThreadsDrained=True, managerExitCode=0, runtimeCleanup=dict(ownedRuntimeProcessesRemaining=0, signaledMainProcesses=0))}
    return receipts, release, state


class ManagerDurabilityAnalysisTests(unittest.TestCase):
    def test_model_passes_with_explicit_scope_only(self):
        result = A.qualify(*model()); self.assertFalse(result['crashRecoveryQualified']); self.assertFalse(result['backupRestoreQualified']); self.assertFalse(result['releaseGate'])

    def test_missing_fences_lost_data_wrong_generation_or_forced_exit_refuse(self):
        def event(r): return next(e for e in r['fixture-ledger.json']['events'] if e['kind'] == 'durability-result' and e['phase'] == 'read')
        changes = [lambda r:r['durability-custody-deadline.json'].update(at=6), lambda r:r['durability-custody-deadline.json']['browser'].update(startMicroseconds=2),
            lambda r:r['durability-custody-cancelled.json'].update(sessionGeneration='other'), lambda r:r['durability-custody-read.json'].update(sessionGeneration='first'),
            lambda r:r['durability-custody-read.json'].update(metadataIdentitySHA256='c' * 64), lambda r:r['durability-custody-read.json'].update(runtimeExecutableSHA256='c' * 64),
            lambda r:r['durability-custody-read.json'].update(durabilityProbeSHA256='c' * 64), lambda r:event(r).update(allPersistentValuesMatch=False),
            lambda r:event(r).update(wrote=True), lambda r:event(r).update(sessionStorageFresh=False), lambda r:event(r)['peer'].update(sessionGeneration='first'),
            lambda r:r['fixture-ledger.json']['runtimeCleanup'].update(signaledMainProcesses=1), lambda r:r['durability-custody-cleanup.json'].update(ownedProcessesRemaining=1),
            lambda r:r['durability-custody-cleanup.json']['browserExits']['exits'][0].update(status=15), lambda r:r['durability-custody-cleanup.json']['browserExits']['exits'].pop()]
        changes += [lambda r, flag=flag:r['durability-ui.json'].update({flag: False}) for flag in A.UI_FLAGS]
        for index, change in enumerate(changes):
            receipts, release, state = model(); change(receipts)
            with self.subTest(index=index), self.assertRaises(ValueError): A.qualify(receipts, release, state)


if __name__ == '__main__': unittest.main()
