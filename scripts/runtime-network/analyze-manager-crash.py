#!/usr/bin/env python3
"""Qualify only the declared main-crash scope; no power-loss/relay/WebKit claim."""
import argparse
import importlib.util
import json
from pathlib import Path

def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
C = module('crash_analysis_custody', 'collect-manager-crash.py')
W = module('crash_analysis_shared', 'analyze-manager-websocket.py')
P = W.P
require = P.require
HASHES = dict(fixtureSHA256='manager-route-fixture.py', crashFixtureSHA256='manager-crash-fixture.py',
              crashProbeSHA256='manager-crash-probe.js', collectorSHA256='collect-manager-dns.py',
              crashCollectorSHA256='collect-manager-crash.py', peerCollectorSHA256='collect-manager-webrtc.py')
INPUTS = (*(f'crash-custody-{stage}.json' for stage in C.LIVE_STAGES), 'crash-intent.json', 'crash-signal.json',
          'crash-after.json', 'crash-cleanup.json', 'fixture-ledger.json', 'crash-ui.json')
UI_FLAGS = ('ownedDocumentGuard', 'baselineComplete', 'baselineNormalStop', 'mutateComplete',
            'recoveryStoppedBeforeLaunch', 'readComplete', 'nativeStopQuitUsed')


def measure_components(receipts, release, state):
    """Verify data/custody layers without hiding a failed whole-scenario gate."""
    try:
        baseline, mutate, read = [receipts['crash-custody-' + s + '.json'] for s in C.LIVE_STAGES]
        intent, sent, after, cleanup, ledger, ui = [receipts[n] for n in INPUTS[3:]]
        samples = (baseline,mutate,read); events = ledger['events']
        peer_source, peer_socket = C.peer_socket_binding()
        require(peer_source == state['peerCollectorSHA256'], 'crash-peer-source-binding')
        require(ledger['managerExitCode'] == 0 and type(ledger['managerExitCode']) is int and ledger['serverThreadsDrained'] is True
                and ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining'] == ledger['runtimeCleanup']['signaledMainProcesses'] == 0, 'crash-fixture-cleanup')
        expected = [dict(reason=1,status=0),dict(reason=2,status=9),dict(reason=1,status=0)]
        require(cleanup['observedExits'] == expected and cleanup['ownedProcessesRemaining'] == 0 and cleanup['capturedGenerationsAbsent'] is True
                and cleanup['leaseAbsent'] is True and cleanup['ordinaryInstanceTouched'] is False and P.digest(cleanup['logSHA256']), 'crash-native-exits-cleanup')
        times = [s['at'] for s in (baseline,mutate,intent,sent,after,read,cleanup)]
        require(all(P.number(t) for t in times) and times == sorted(set(times)), 'crash-order')
        require([s['crashStage'] for s in samples] == list(C.LIVE_STAGES) and baseline['manager']['pid'] == state['managerPID']
                and baseline['profileID'] == state['profiles'][1]['id'].lower(), 'crash-state-binding')
        for s in samples:
            P.process(s['manager']); P.process(s['browser'])
            tree = s['runtimeProcesses']
            require(isinstance(tree,list) and 1 <= len(tree) <= 128 and tree[0]['identity'] == s['browser'], 'crash-process-tree-missing')
            known = {s['manager']['pid']}
            for item in tree:
                P.process(item['identity'])
                require(item['identity']['parentPID'] in known and item['identity']['pid'] not in known, 'crash-process-tree-invalid')
                known.add(item['identity']['pid'])
            require(s['phase'] == 'direct-control' and s.get('relay') is None and s['manager'] == baseline['manager']
                    and s['profileID'] == baseline['profileID'] and s['metadataIdentitySHA256'] == baseline['metadataIdentitySHA256']
                    and s['browser']['parentPID'] == s['manager']['pid'] and s['managerSHA256'] == state['managerSHA256'] == release['managerSHA256']
                    and s['version'] == state['version'] == release['version'] and str(s['build']) == str(state['build']) == str(release['build']), 'crash-app-profile-binding')
            for key in (*HASHES,'candidateManifestSHA256'):
                require(P.digest(s[key]) and s[key] == baseline[key], 'crash-source-binding')
            for key in ('fixtureSHA256','crashFixtureSHA256','crashProbeSHA256','candidateManifestSHA256','peerCollectorSHA256'):
                require(s[key] == state[key], 'crash-state-source-binding')
            require(P.digest(s['peerSocketCodeSHA256']) and s['peerSocketCodeSHA256'] == peer_socket,
                    'crash-peer-import-binding')
            require(s['runtimeExecutableSHA256'] == release['runtime']['executableSHA256']
                    and s['runtimeFrameworkSHA256'] == release['runtime']['frameworkSHA256'], 'crash-runtime-binding')
        require(len({s['sessionGeneration'] for s in samples}) == len({(s['browser']['pid'],s['browser']['startSeconds'],s['browser']['startMicroseconds']) for s in samples}) == 3
                and baseline['revision'] < mutate['revision'] < read['revision'], 'crash-not-fresh-sessions')
        C.validate_target(mutate,intent['custody'],events)
        require(intent['signal'] == sent['signal'] == 9 and sent['issued'] is True and sent['processGroupSignaled'] is False
                and sent['ordinaryInstanceTouched'] is False and sent['target'] == intent['target'] == mutate['browser']
                and intent['manager'] == baseline['manager'] and intent['collectorSHA256'] == sent['collectorSHA256'] == mutate['crashCollectorSHA256'], 'crash-signal-binding')
        require(isinstance(intent['descendants'],list) and 1 <= len(intent['descendants']) <= 128
                and intent['descendants'] == intent['custody']['runtimeProcesses']
                and intent['descendants'][0]['identity'] == mutate['browser'], 'crash-descendants-missing')
        for item in intent['descendants']: P.process(item['identity'])
        require(after['manager'] == baseline['manager'] and after['signal'] == 9 and after['mainGenerationAbsent'] is True
                and after['capturedDescendantsAbsent'] is True and after['capturedDescendantCount'] == len(intent['descendants'])
                and after['leaseRetired'] is True and type(after['dataOpenFiles']) is int and after['dataOpenFiles'] == 0
                and after['observedExits'] == expected[:2] and after['collectorSHA256'] == cleanup['collectorSHA256'] == mutate['crashCollectorSHA256'], 'crash-premature-relaunch')
        require(ui['source'] == 'native-cua-operator-reduction' and ui['managerPID'] == baseline['manager']['pid'] and ui['profileID'] == baseline['profileID']
                and all(ui[key] is True for key in UI_FLAGS), 'crash-native-ui-incomplete')
        require(isinstance(events,list) and 0 < len(events) <= 128 and all(P.number(e['at']) for e in events)
                and [e['at'] for e in events] == sorted(e['at'] for e in events), 'crash-page-protocol')
        for sample,phase,low in ((baseline,'baseline',0),(mutate,'mutate',baseline['at']),(read,'read',after['at'])):
            pages = [e for e in events if e['kind'] == 'crash-page' and e.get('phase') == phase]
            results = [e for e in events if e['kind'] == 'crash-result' and e.get('phase') == phase]
            require(len(pages) == len(results) == 1, 'crash-page-or-result-missing')
            page,result = pages[0],results[0]
            require(low < page['at'] < result['at'] <= sample['at'], 'crash-data-window')
            for e in (page,result): P.peer_matches(e['peer'],sample,False)
            require(result['baselineIntact'] is True and result['abortedValueAbsent'] is True
                    and result['strictIDBRetained'] is (phase != 'baseline') and result['strictCompleted'] is (phase != 'read')
                    and result['abortedAfterRequestSuccess'] is (phase == 'mutate') and result['wrote'] is (phase != 'read'), 'crash-data-loss-or-repair')
            require(set(result['freshPresence']) == {'cookie','localStorage','indexedDB','cacheStorage'}
                    and all(type(v) is bool for v in result['freshPresence'].values()) and type(result['sessionRestored']) is bool
                    and result['freshPresence']['indexedDB'] is (phase != 'baseline'), 'crash-observation-shape')
            if phase != 'read':
                require(all(v is (phase == 'mutate') for v in result['freshPresence'].values())
                        and result['sessionRestored'] is (phase == 'mutate'), 'crash-baseline-or-write-observation')
    except (KeyError,TypeError,IndexError,AttributeError) as error: raise ValueError('crash-evidence-incomplete') from error
    observed = next(e for e in events if e['kind']=='crash-result' and e.get('phase')=='read')
    refused = sum(e['kind'] == 'crash-http-refused' for e in events)
    return dict(schemaVersion=1,result='scoped-own-main-crash-components-only',version=release['version'],build=release['build'],
                baselinePreserved=True,acknowledgedStrictIDBPreserved=True,abortedRequestNotCommitted=True,readWithoutRepair=True,
                intentionalMainSignals=1,cleanupSignals=0,normalMainExits=2,freshPresence=observed['freshPresence'],
                unclassifiedHTTPRefusals=refused,httpProtocolQualified=refused == 0,fullScenarioQualified=False,
                sessionRestored=observed['sessionRestored'],powerLossQualified=False,relayCrashQualified=False,WebKitQualified=False,
                backupRestoreQualified=False,releaseGate=False,limitation='One own Direct profile/main SIGKILL on one Mac;fresh cookie/LS/cache are observations,not strict disk guarantees')


def qualify(receipts, release, state):
    value = measure_components(receipts, release, state)
    require(value['unclassifiedHTTPRefusals'] == 0, 'crash-page-protocol')
    return dict(value, result='scoped-own-main-crash-recovery-pass', fullScenarioQualified=True)


def analyze(directory, release, *, components_only=False):
    state,_ = C.owned_state(directory / 'private-state.json'); receipts = {n:C.CORE.load(directory/n) for n in INPUTS}
    for key,name in HASHES.items():
        actual = C.CORE.sha(Path(__file__).with_name(name).read_bytes())
        require(all(receipts['crash-custody-'+s+'.json'][key] == actual for s in C.LIVE_STAGES), 'crash-source-drift')
    result = (measure_components if components_only else qualify)(receipts,release,state)
    result['inputSHA256'] = {n:C.CORE.sha(C.CORE.read_private(directory/n)) for n in INPUTS}
    result['analyzerSHA256'] = C.CORE.sha(Path(__file__).read_bytes()); return result


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--receipts',type=Path,required=True)
    parser.add_argument('--release',type=Path,required=True)
    parser.add_argument('--components-only',action='store_true',help='Explicit non-qualifying layer report;never whole-scenario PASS or a release gate')
    args=parser.parse_args()
    try: value=analyze(args.receipts,W.load_release(args.release),components_only=args.components_only)
    except (ValueError,OSError): parser.exit(1,'Own main-crash recovery evidence refused.\n')
    print(json.dumps(value,indent=2))


if __name__=='__main__': main()
