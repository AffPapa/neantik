#!/usr/bin/env python3
"""Join actual close-delay UI, signed session custody and fresh data reads."""
import argparse
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('durability_analysis_custody', Path(__file__).with_name('collect-manager-durability.py'))
C = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(C)
WS_SPEC = importlib.util.spec_from_file_location('durability_analysis_shared', Path(__file__).with_name('analyze-manager-websocket.py'))
W = importlib.util.module_from_spec(WS_SPEC); WS_SPEC.loader.exec_module(W)
P = W.P
require, process, digest = P.require, P.process, P.digest
HASHES = dict(fixtureSHA256='manager-route-fixture.py', durabilityFixtureSHA256='manager-durability-fixture.py',
              durabilityProbeSHA256='manager-durability-probe.js', collectorSHA256='collect-manager-dns.py',
              durabilityCollectorSHA256='collect-manager-durability.py', peerCollectorSHA256='collect-manager-webrtc.py')
INPUTS = ('fixture-ledger.json', 'durability-ui.json', *(f'durability-custody-{stage}.json' for stage in (*C.STAGES, 'cleanup')))
UI_FLAGS = ('ownedDocumentGuard', 'beforeunloadArmed', 'managerClosingVisible', 'pageConfirmationVisible',
            'managerTimeoutWarningVisible', 'launchNotOffered', 'editDisabled', 'pageConfirmationCancelled',
            'beforeunloadDisarmed', 'readPageComplete', 'nativeStopQuitUsed')


def qualify(receipts, release, state):
    try:
        samples = [receipts['durability-custody-' + stage + '.json'] for stage in C.STAGES]
        written, pending, deadline, cancelled, read = samples
        cleanup = receipts['durability-custody-cleanup.json']; ledger = receipts['fixture-ledger.json']; ui = receipts['durability-ui.json']
        require(ledger['serverThreadsDrained'] is True and type(ledger['managerExitCode']) is int and ledger['managerExitCode'] == 0
                and ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining'] == ledger['runtimeCleanup']['signaledMainProcesses'] == 0, 'durability-fixture-cleanup')
        require(cleanup['ownedProcessesRemaining'] == 0 and cleanup['ordinaryInstanceTouched'] is False and digest(cleanup['logSHA256'])
                and cleanup['browserExits'] == dict(launchCount=2, exits=[dict(reason=1, status=0)] * 2), 'durability-normal-exits')
        require([s['durabilityStage'] for s in samples] == list(C.STAGES) and all(P.number(s['at']) for s in [*samples, cleanup])
                and [s['at'] for s in [*samples, cleanup]] == sorted(set(s['at'] for s in [*samples, cleanup]))
                and deadline['at'] - pending['at'] >= 8, 'durability-deadline-window')
        require(written['manager']['pid'] == state['managerPID'] and written['managerSHA256'] == state['managerSHA256']
                and written['candidateManifestSHA256'] == state['candidateManifestSHA256']
                and written['profileID'] == state['profiles'][1]['id'].lower(), 'durability-state-binding')
        for sample in samples:
            process(sample['manager']); process(sample['browser'])
            require(sample['phase'] == 'direct-control' and sample.get('relay') is None and sample['manager'] == written['manager']
                    and sample['profileID'] == written['profileID'] and sample['metadataIdentitySHA256'] == written['metadataIdentitySHA256']
                    and sample['browser']['parentPID'] == sample['manager']['pid'] and sample['managerSHA256'] == release['managerSHA256']
                    and sample['version'] == state['version'] == release['version'] and str(sample['build']) == str(state['build']) == str(release['build']), 'durability-app-profile-binding')
            for key in (*HASHES, 'candidateManifestSHA256'):
                require(digest(sample[key]) and sample[key] == written[key], 'durability-source-binding')
            for key in ('fixtureSHA256', 'durabilityFixtureSHA256', 'durabilityProbeSHA256'): require(sample[key] == state[key], 'durability-fixture-binding')
            require(sample['runtimeExecutableSHA256'] == release['runtime']['executableSHA256']
                    and sample['runtimeFrameworkSHA256'] == release['runtime']['frameworkSHA256'], 'durability-runtime-binding')
        for sample in (pending, deadline, cancelled):
            for key in ('browser', 'sessionGeneration', 'leaseSHA256', 'revision', 'lastLaunchedAt', 'updatedAt'):
                require(sample[key] == written[key], 'durability-surviving-session-changed')
        require(read['browser'] != written['browser'] and read['sessionGeneration'] != written['sessionGeneration']
                and type(read['revision']) is int and read['revision'] > written['revision'], 'durability-reopen-not-fresh')
        require(ui['source'] == 'native-cua-operator-reduction' and ui['managerPID'] == written['manager']['pid']
                and ui['profileID'] == written['profileID'] and ui['firstBrowserPID'] == written['browser']['pid']
                and ui['readBrowserPID'] == read['browser']['pid'] and all(ui[key] is True for key in UI_FLAGS), 'durability-native-ui-incomplete')
        events = ledger['events']
        require(isinstance(events, list) and 0 < len(events) <= 128 and all(P.number(e['at']) for e in events)
                and [e['at'] for e in events] == sorted(e['at'] for e in events), 'durability-ledger-order')
        require(not any(e['kind'] == 'durability-http-refused' for e in events), 'durability-page-protocol-failure')
        for sample, phase, low in ((written, 'write', 0), (read, 'read', cancelled['at'])):
            pages = [e for e in events if e['kind'] == 'durability-page' and e.get('phase') == phase]
            results = [e for e in events if e['kind'] == 'durability-result' and e.get('phase') == phase]
            require(len(pages) == len(results) == 1, 'durability-data-observations-missing')
            page, result = pages[0], results[0]
            require(low < page['at'] < result['at'] <= sample['at'], 'durability-data-window')
            for e in (page, result): P.peer_matches(e['peer'], sample, False)
            require(result['allPersistentValuesMatch'] is True and result['wrote'] is (phase == 'write')
                    and result['freshBeforeWrite'] is (phase == 'write') and result['strictIDB'] is (phase == 'write')
                    and result['sessionStorageFresh'] is (phase == 'read'), 'durability-data-loss-or-repair')
    except (KeyError, TypeError, IndexError, AttributeError) as error: raise ValueError('durability-evidence-incomplete') from error
    return dict(schemaVersion=1, result='scoped-manager-delayed-close-data-pass', version=release['version'], build=release['build'],
                persistentStores=['cookie', 'LocalStorage', 'IndexedDB', 'CacheStorage'], nativeDeadlineSecondsMinimum=8,
                sameBrowserLeaseSurvivedDeadline=True, normalMainExits=2, readWithoutRepair=True,
                crashRecoveryQualified=False, backupRestoreQualified=False, WebKitQualified=False, releaseGate=False,
                limitation='Own beforeunload-delayed close,normal resume/quit and one Direct Chromium profile on this Mac;not abrupt crash,power loss or full backup')


def analyze(directory, release):
    state, _ = C.owned_state(directory / 'private-state.json'); receipts = {name: C.CORE.load(directory / name) for name in INPUTS}
    for key, name in HASHES.items():
        actual = C.CORE.sha(Path(__file__).with_name(name).read_bytes())
        require(all(receipts['durability-custody-' + stage + '.json'][key] == actual for stage in C.STAGES), 'durability-source-drift')
    result = qualify(receipts, release, state)
    result['inputSHA256'] = {name: C.CORE.sha(C.CORE.read_private(directory / name)) for name in INPUTS}
    result['analyzerSHA256'] = C.CORE.sha(Path(__file__).read_bytes()); return result


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--receipts', type=Path, required=True)
    parser.add_argument('--release', type=Path, required=True); args = parser.parse_args()
    try: result = analyze(args.receipts, W.load_release(args.release))
    except (ValueError, OSError): parser.exit(1, 'Own delayed-close data evidence refused.\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
