#!/usr/bin/env python3
"""Offline WS operations + actual manager/relay generations + origin custody."""
import argparse
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('manager_ws_analysis_custody', Path(__file__).with_name('collect-manager-websocket.py'))
C = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(C)
PEER_SPEC = importlib.util.spec_from_file_location('manager_ws_peer_validation', Path(__file__).with_name('analyze-manager-webrtc.py'))
P = importlib.util.module_from_spec(PEER_SPEC); PEER_SPEC.loader.exec_module(P)
require, digest, process = P.require, P.digest, P.process
HASHES = dict(fixtureSHA256='manager-route-fixture.py', websocketFixtureSHA256='manager-websocket-fixture.py',
              websocketProbeSHA256='manager-websocket-probe.js', collectorSHA256='collect-manager-dns.py', websocketCollectorSHA256='collect-manager-websocket.py')
HASHES['peerCollectorSHA256'] = 'collect-manager-webrtc.py'
INPUTS = ('fixture-ledger.json', *(f'ws-custody-{phase}.json' for phase in (*C.PHASES, 'cleanup')))


def qualify(receipts, release, state):
    try:
        before, success, direct = [receipts['ws-custody-' + p + '.json'] for p in C.PHASES]
        cleanup = receipts['ws-custody-cleanup.json']; ledger = receipts['fixture-ledger.json']; events = ledger['events']
        require(ledger['serverThreadsDrained'] is True and type(ledger['managerExitCode']) is int and ledger['managerExitCode'] == 0
                and ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining'] == ledger['runtimeCleanup']['signaledMainProcesses'] == 0, 'ws-fixture-cleanup')
        require(cleanup['ownedProcessesRemaining'] == 0 and cleanup['ordinaryInstanceTouched'] is False, 'ws-process-cleanup')
        require([s['phase'] for s in (before, success, direct)] == list(C.PHASES)
                and all(P.number(s['at']) for s in (before, success, direct, cleanup))
                and before['at'] < success['at'] < direct['at'] < cleanup['at'], 'ws-custody-order')
        require(isinstance(events, list) and 0 < len(events) <= 512 and all(P.number(e['at']) for e in events)
                and [e['at'] for e in events] == sorted(e['at'] for e in events), 'ws-ledger-order')
        require(before['manager']['pid'] == state['managerPID'] and before['managerSHA256'] == state['managerSHA256']
                and before['candidateManifestSHA256'] == state['candidateManifestSHA256']
                and before['profileID'] == state['profiles'][0]['id'].lower()
                and before['directBaseline']['profileID'] == state['profiles'][1]['id'].lower(), 'ws-state-binding')
        for sample in (before, success, direct):
            process(sample['manager'])
            require(sample['manager'] == before['manager'] and sample['managerSHA256'] == release['managerSHA256']
                    and sample['version'] == state['version'] == release['version'] and str(sample['build']) == str(state['build']) == str(release['build']), 'ws-app-binding')
            for key in (*HASHES, 'candidateManifestSHA256'):
                require(digest(sample[key]) and sample[key] == before[key], 'ws-source-binding')
            for key in ('fixtureSHA256', 'websocketFixtureSHA256', 'websocketProbeSHA256'): require(sample[key] == state[key], 'ws-fixture-binding')
        require(success['profileID'] == before['profileID'] and direct['profileID'] == before['directBaseline']['profileID']
                and success['profileID'] != direct['profileID'] and direct.get('relay') is None, 'ws-profile-boundary')
        for sample in (success, direct):
            process(sample['browser']); require(sample['browser']['parentPID'] == before['manager']['pid'], 'ws-browser-parent')
            require(sample['runtimeExecutableSHA256'] == release['runtime']['executableSHA256']
                    and sample['runtimeFrameworkSHA256'] == release['runtime']['frameworkSHA256'], 'ws-runtime-binding')
        process(success['relayOwner']); relay = success['relay']; owner = success['relayOwner']
        require(owner['parentPID'] == before['manager']['pid'] and relay['ownerPID'] == owner['pid']
                and relay['ownerUID'] == owner['uid'] and relay['ownerStartSeconds'] == owner['startSeconds']
                and relay['ownerStartMicroseconds'] == owner['startMicroseconds']
                and relay['profileID'].lower() == success['profileID'] and relay['sessionGeneration'].lower() == success['sessionGeneration']
                and relay['configurationSHA256'] == success['configurationSHA256'] and digest(success['configurationSHA256'])
                and digest(success['leaseSHA256']) and relay['runtimeExecutableSHA256'] == release['runtime']['executableSHA256']
                and relay['runtimeFrameworkSHA256'] == release['runtime']['frameworkSHA256'], 'ws-relay-binding')
        for index, sample in enumerate((success, direct)):
            mode = sample['phase']; protected = mode == 'proxy-success'; low = (before, success)[index]['at']; high = sample['at']
            subset = lambda kind: [e for e in events if e['kind'] == kind and e.get('mode') == mode]
            controls, pages, results, handshakes = [subset(kind) for kind in ('ws-control', 'ws-page', 'ws-result', 'ws-handshake')]
            require(len(pages) == len(results) == 1 and [e['phase'] for e in controls] == ['initial', 'blocked', 'recovered'], 'ws-operations-missing')
            page, result = pages[0], results[0]
            require(low < page['at'] < controls[0]['at'] < controls[1]['at'] < controls[2]['at'] < result['at'] <= high, 'ws-phase-window')
            require(controls[1]['channelsCut'] == (2 if protected else 0), 'ws-live-cut-missing')
            expected = ['initial', 'recovered'] if protected else ['initial', 'blocked', 'recovered']
            require([e['phase'] for e in handshakes] == expected, 'ws-handshake-boundary')
            for event in (page, result, *handshakes):
                require(event['peer']['route'] == ('proxy' if protected else 'direct'), 'ws-direct-bypass')
                P.peer_matches(event['peer']['custody'], sample, protected)
            for handshake in handshakes:
                phase_index = ('initial', 'blocked', 'recovered').index(handshake['phase'])
                lower = controls[phase_index]['at']; upper = controls[phase_index + 1]['at'] if phase_index < 2 else result['at']
                require(lower < handshake['at'] < upper, 'ws-handshake-window')
                echoes = [e for e in events if e['kind'] == 'ws-echo' and e.get('eventID') == handshake['eventID']]
                closes = [e for e in events if e['kind'] == 'ws-closed' and e.get('eventID') == handshake['eventID']]
                require(len(echoes) == len(closes) == 1 and handshake['at'] < echoes[0]['at'] < closes[0]['at'] < result['at']
                        and echoes[0]['mode'] == mode and echoes[0]['phase'] == handshake['phase'], 'ws-echo-close-missing')
            refused = subset('ws-connect-refused')
            require(bool(refused) is protected and all(controls[1]['at'] < e['at'] < controls[2]['at'] for e in refused), 'ws-refusal-missing')
            value = result['result']; require(value['mode'] == mode and value['errors'] == [] and type(value['remaining']) is int and value['remaining'] == 0, 'ws-page-incomplete')
            rows = value['rows']; require([row['phase'] for row in rows] == ['initial', 'blocked', 'recovered'], 'ws-page-rows')
            for row in rows:
                works = row['phase'] != 'blocked' or not protected
                require(row['opened'] is works and row['echoed'] is works and row['errored'] is (not works)
                        and row['closeCode'] == (1006 if protected and row['phase'] in ('initial', 'blocked') else 1000), 'ws-page-behavior')
            require(value['held'] == (dict(aborted=True, closeCode=1006) if protected else dict(stillOpen=True)), 'ws-live-behavior')
        exits = cleanup['browserExitObservations']
        require(len(exits) == 2 and {x['profileID'] for x in exits} == {success['profileID'], direct['profileID']}
                and all(x['launchCount'] == 1 and x['terminationReason'] == 1 and x['terminationStatus'] == 0 and digest(x['logSHA256']) for x in exits), 'ws-normal-exit-missing')
    except (KeyError, TypeError, IndexError, AttributeError) as error: raise ValueError('ws-evidence-incomplete') from error
    return dict(schemaVersion=1, result='scoped-manager-relay-ws-pass', version=release['version'], build=release['build'],
                protocol='ws', actualOriginHandshakes=5, protectedDirectHandshakes=0, protectedProxyHandshakes=2,
                normalBrowserExits=2, globalNetworkQualified=False, WSSQualified=False, releaseGate=False,
                limitation='Own WS-only CONNECT refusal/cut with HTTP control retained;not physical listener loss,WSS,WebKit or global DNS/UDP')


def analyze(directory, release):
    state, _ = C.owned_state(directory / 'private-state.json'); receipts = {name: C.CORE.load(directory / name) for name in INPUTS}
    for key, name in HASHES.items():
        actual = C.CORE.sha(Path(__file__).with_name(name).read_bytes())
        require(all(receipts['ws-custody-' + phase + '.json'][key] == actual for phase in C.PHASES), 'ws-source-drift')
    result = qualify(receipts, release, state)
    result['inputSHA256'] = {name: C.CORE.sha(C.CORE.read_private(directory / name)) for name in INPUTS}
    result['analyzerSHA256'] = C.CORE.sha(Path(__file__).read_bytes()); return result


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--receipts', type=Path, required=True)
    parser.add_argument('--release', type=Path, required=True); args = parser.parse_args()
    try: result = analyze(args.receipts, C.CORE.load(args.release))
    except (ValueError, OSError): parser.exit(1, 'Manager WS evidence refused.\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
