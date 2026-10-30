#!/usr/bin/env python3
"""Join physical-listener, owned browser AX, kernel custody and origin evidence.

This qualifies a bounded listener-loss/recovery scenario, not network changes,
global DNS/UDP, HTTPS upstream trust or the complete 1.0 network requirement.
"""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location('tcp_analysis_custody', Path(__file__).with_name('collect-manager-tcp.py'))
TCP = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(TCP)
PHASES = TCP.PHASES
INPUTS = ('fixture-ledger.json', 'tcp-browser-failure.json', *(f'tcp-custody-{phase}.json' for phase in (*PHASES, 'cleanup')))
HASHES = dict(fixtureSHA256='manager-route-fixture.py', tcpFixtureSHA256='manager-tcp-fixture.py',
              collectorSHA256='collect-manager-dns.py', tcpCollectorSHA256='collect-manager-tcp.py')
AX_SPEC = importlib.util.spec_from_file_location('tcp_analysis_ax_reducer',Path(__file__).with_name('observe-manager-tcp-failure.py'))
AX = importlib.util.module_from_spec(AX_SPEC); AX_SPEC.loader.exec_module(AX)


def require(value, reason):
    if not value: raise ValueError(reason)


def number(value): return type(value) in (int, float) and math.isfinite(value) and value >= 0
def digest(value): return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def process(value):
    require(isinstance(value,dict) and all(type(value[k]) is int and value[k] > 0 for k in ('pid','parentPID','startSeconds'))
            and type(value['uid']) is int and value['uid'] >= 0
            and type(value['startMicroseconds']) is int and 0 <= value['startMicroseconds'] < 1_000_000
            and isinstance(value['cdhash'],str) and re.fullmatch('[0-9a-f]{40}',value['cdhash']), 'process-generation-invalid')


def qualify(receipts, release, state):
    try:
        ledger = receipts['fixture-ledger.json']; events = ledger['events']
        require(ledger['serverThreadsDrained'] is True and type(ledger['managerExitCode']) is int
                and ledger['managerExitCode'] == 0 and type(ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining']) is int
                and ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining'] == 0, 'cleanup-not-settled')
        require(isinstance(events, list) and 0 < len(events) <= 4096
                and all(isinstance(e,dict) and number(e['at']) and isinstance(e['kind'],str) for e in events), 'invalid-events')
        require([e['at'] for e in events] == sorted(e['at'] for e in events), 'unordered-events')
        controls = [e for e in events if e['kind']=='tcp-listener-control']
        require(len(controls)==3, 'physical-controls-missing')
        for event, epoch, active in zip(controls, (0,1,2), (True,False,True)):
            require(type(event['faultEpoch']) is int and event['faultEpoch']==epoch and event['listenerActive'] is active, 'physical-control-differs')
        start, loss, reset = [e['at'] for e in controls]
        require(start < loss < reset and controls[1]['socketProbeRefused'] is True
                and controls[2]['sameEndpoint'] is True, 'physical-listener-refusal-or-rebind-missing')
        samples = [receipts['tcp-custody-'+phase+'.json'] for phase in PHASES]
        before, success, refused, direct, recovered = samples
        require(all(s['phase']==phase and number(s['at']) for s,phase in zip(samples,PHASES)), 'custody-phase-differs')
        require([s['at'] for s in samples] == sorted(set(s['at'] for s in samples)), 'custody-order-differs')
        for sample in samples:
            process(sample['manager'])
            require(sample['manager']==before['manager'] and sample['managerSHA256']==release['managerSHA256']
                    and sample['version']==release['version'] and str(sample['build'])==str(release['build']), 'manager-binding-differs')
            for key in (*HASHES,'candidateManifestSHA256'):
                require(digest(sample[key]) and sample[key]==before[key], 'source-binding-differs')
        protected = (success,refused,recovered)
        for sample in protected:
            process(sample['browser']); process(sample['relayOwner'])
            for key in ('browser','relayOwner','relay','profileID','revision','metadataIdentitySHA256',
                        'updatedAt','lastLaunchedAt','sessionGeneration','leaseSHA256','configurationSHA256'):
                require(sample[key]==success[key], 'protected-session-changed')
            relay = sample['relay']
            require(digest(sample['leaseSHA256']) and digest(sample['configurationSHA256'])
                    and sample['profileID']==before['profileID']
                    and relay['profileID'].lower()==sample['profileID']
                    and relay['sessionGeneration'].lower()==sample['sessionGeneration']
                    and relay['configurationSHA256']==sample['configurationSHA256'], 'lease-binding-differs')
            require(relay['runtimeExecutableSHA256']==release['runtime']['executableSHA256']
                    and relay['runtimeFrameworkSHA256']==release['runtime']['frameworkSHA256'], 'runtime-binding-differs')
            require(sample['browser']['parentPID']==sample['relayOwner']['parentPID']==before['manager']['pid']
                    and relay['ownerPID']==sample['relayOwner']['pid']
                    and relay['ownerStartSeconds']==sample['relayOwner']['startSeconds']
                    and relay['ownerStartMicroseconds']==sample['relayOwner']['startMicroseconds']
                    and relay['ownerUID']==sample['relayOwner']['uid'], 'generation-binding-differs')
        process(direct['browser'])
        require(direct['profileID']==before['directBaseline']['profileID'] and direct['profileID']!=success['profileID']
                and direct.get('relay') is None and direct['browser']['pid']!=success['browser']['pid']
                and direct['browser']['parentPID']==before['manager']['pid'], 'direct-control-not-independent')
        require(before['at'] < success['at'] < loss < refused['at'] < direct['at'] < reset < recovered['at'], 'phase-window-differs')
        failure = receipts['tcp-browser-failure.json']
        require(failure['observationMethod']=='operator-owned-CUA-AX' and digest(failure['reducedAXSHA256'])
                and failure['phase']=='listener-refused' and failure['browser']==success['browser']
                and failure['leaseSHA256']==success['leaseSHA256'] and failure['configurationSHA256']==success['configurationSHA256']
                and failure['expectedURLSHA256']==TCP.CORE.sha(state['urls']['listener-refused'].encode())
                and failure['errorCode'] in ('ERR_SOCKS_CONNECTION_FAILED','ERR_PROXY_CONNECTION_FAILED','ERR_TUNNEL_CONNECTION_FAILED')
                and loss < failure['at'] <= refused['at'], 'fresh-browser-failure-not-observed')
        require(direct['at'] - failure['at'] >= 5, 'failure-window-too-short')
        origins = [e for e in events if e['kind']=='tcp-origin-arrival']
        require(all(type(e['throughOwnedUpstream']) is bool for e in origins), 'origin-route-invalid')
        positive = [e for e in origins if e['phase']=='proxy-success' and e['throughOwnedUpstream']]
        recovered_hits = [e for e in origins if e['phase']=='proxy-recovered' and e['throughOwnedUpstream']]
        direct_hits = [e for e in origins if e['phase']=='direct-control' and not e['throughOwnedUpstream']]
        require(positive and recovered_hits and direct_hits, 'origin-control-missing')
        for phase, protected_route in [('proxy-success',True),('direct-control',False),('proxy-recovered',True)]:
            require(any(e['kind']=='origin' and e['phase']==phase and e['throughOwnedUpstream'] is protected_route
                        for e in events), 'origin-response-missing')
        require(all(before['at'] < e['at'] <= success['at'] and e['faultEpoch']==0 and e['listenerActive'] is True for e in positive), 'positive-window-invalid')
        require(all(refused['at'] < e['at'] <= direct['at'] and e['faultEpoch']==1 and e['listenerActive'] is False for e in direct_hits), 'direct-not-during-refusal')
        require(all(reset < e['at'] <= recovered['at'] and e['faultEpoch']==2 and e['listenerActive'] is True for e in recovered_hits), 'recovery-window-invalid')
        require(not any(loss <= e['at'] < reset and e not in direct_hits for e in origins), 'origin-during-protected-failure')
        require(not any(not e['throughOwnedUpstream'] and e not in direct_hits for e in origins), 'unexpected-direct-arrival')
        for kind, phase, low, high, sample in [('tcp-request-peer',None,before['at'],success['at'],success),
                ('tcp-request-peer',None,reset,recovered['at'],success),
                ('tcp-direct-peer','direct-control',refused['at'],direct['at'],direct)]:
            peers = [e for e in events if e['kind']==kind and low < e['at'] <= high and (phase is None or e.get('phase')==phase)]
            require(peers, 'live-socket-custody-missing')
            for peer in peers:
                require(peer['manager']==before['manager'] and peer['browser']==sample['browser']
                        and peer['sessionGeneration']==sample['sessionGeneration'] and peer['profileID']==sample['profileID']
                        and digest(peer['socketTupleSHA256']) and bool(peer['peerChain']), 'peer-session-differs')
                require(peer['configurationSHA256']==(None if sample is direct else success['configurationSHA256']), 'peer-config-differs')
                require(peer['peerChain'][0]==success['relayOwner'] if sample is not direct else peer['peerChain'][-1]==direct['browser'], 'peer-owner-differs')
        cleanup = receipts['tcp-custody-cleanup.json']
        require(cleanup['ownedProcessesRemaining']==0 and type(cleanup['ownedProcessesRemaining']) is int
                and cleanup['ordinaryInstanceTouched'] is False and cleanup['at'] > recovered['at']
                and cleanup['collectorSHA256']==before['tcpCollectorSHA256'], 'owned-cleanup-missing')
    except (KeyError,TypeError,IndexError,AttributeError):
        raise ValueError('missing-or-malformed-tcp-evidence') from None
    return dict(schemaVersion=1,result='scoped-physical-tcp-observations-pass',version=release['version'],build=release['build'],
                runtimeExecutableSHA256=release['runtime']['executableSHA256'], runtimeFrameworkSHA256=release['runtime']['frameworkSHA256'],
                checks=['physical upstream listener refusal','owned browser nonce/error','same manager/browser/relay/session/config',
                        'no protected origin during outage','deliberate Direct sensitivity','same endpoint/session recovery','owned cleanup'],
                globalDNSQualified=False,allNetworkGatesComplete=False,releaseGate=False,
                limitation='Owned listener TCP refusal only; no claim about manager POSIX errno, RST, physical network change, global DNS/UDP or HTTPS upstream')


def analyze(directory, release):
    state, _ = TCP.owned_state(directory / 'private-state.json')
    receipts = {name:TCP.CORE.load(directory/name) for name in INPUTS}
    for key,name in HASHES.items():
        actual = TCP.CORE.sha(Path(__file__).with_name(name).read_bytes())
        require(all(receipts['tcp-custody-'+phase+'.json'][key]==actual for phase in PHASES), 'collector-source-drift')
    require(receipts['tcp-browser-failure.json']['observerSHA256']==TCP.CORE.sha(Path(__file__).with_name('observe-manager-tcp-failure.py').read_bytes()), 'observer-source-drift')
    reduced = TCP.CORE.read_private(directory/'owned-cua-failure-values.txt',65536)
    require(TCP.CORE.sha(reduced)==receipts['tcp-browser-failure.json']['reducedAXSHA256']
            and AX.reduce_values(reduced.decode('utf-8'),state['urls']['listener-refused'])==receipts['tcp-browser-failure.json']['errorCode'], 'retained-cua-observation-differs')
    result = qualify(receipts,release,state)
    result['inputSHA256'] = {name:TCP.CORE.sha(TCP.CORE.read_private(directory/name)) for name in INPUTS}
    result['inputSHA256']['owned-cua-failure-values.txt']=TCP.CORE.sha(reduced)
    result['analyzerSHA256'] = TCP.CORE.sha(Path(__file__).read_bytes())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipts',required=True,type=Path)
    parser.add_argument('--release',required=True,type=Path)
    args=parser.parse_args()
    try:
        result=analyze(args.receipts,json.loads(args.release.read_bytes()))
    except (ValueError,OSError):
        parser.exit(1,'Physical TCP evidence refused.\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__': main()
