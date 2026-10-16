#!/usr/bin/env python3
"""Join normal-page completion, independent UDP and live signed session custody."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re

SPEC=importlib.util.spec_from_file_location('webrtc_analysis_custody',Path(__file__).with_name('collect-manager-webrtc.py'))
W=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(W)
PHASES=W.PHASES
INPUTS=('fixture-ledger.json',*(f'webrtc-custody-{phase}.json' for phase in (*PHASES,'cleanup')))
HASHES={'fixtureSHA256':'manager-route-fixture.py','webrtcFixtureSHA256':'manager-webrtc-fixture.py',
        'webrtcProbeSHA256':'manager-webrtc-probe.js','collectorSHA256':'collect-manager-dns.py','webrtcCollectorSHA256':'collect-manager-webrtc.py'}


def require(value,reason):
    if not value:raise ValueError(reason)


def number(value):return type(value) in (int,float) and math.isfinite(value) and value>=0
def digest(value):return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None
def count(value):return type(value) is int and value>=0


def process(value):
    require(isinstance(value,dict) and all(type(value[k]) is int and value[k]>0 for k in ('pid','parentPID','startSeconds'))
            and type(value['uid']) is int and value['uid']>=0 and type(value['startMicroseconds']) is int
            and 0<=value['startMicroseconds']<1_000_000 and re.fullmatch('[0-9a-f]{40}',value['cdhash']) is not None,'process-generation-invalid')


def peer_matches(peer,sample,protected):
    require(peer['manager']==sample['manager'] and peer['browser']==sample['browser'] and peer['profileID']==sample['profileID']
            and peer['sessionGeneration']==sample['sessionGeneration'] and digest(peer['socketTupleSHA256']),'peer-session-differs')
    chain=peer['peerChain'];require(isinstance(chain,list) and 0<len(chain)<=4,'peer-chain-missing')
    for item in chain:process(item)
    if protected:
        require(chain==[sample['relayOwner']] and peer['configurationSHA256']==sample['configurationSHA256'],'relay-peer-differs')
    else:
        require(chain[-1]==sample['browser'] and all(a['parentPID']==b['pid'] for a,b in zip(chain,chain[1:])),'direct-helper-chain-differs')


def qualify(receipts,release,state):
    try:
        ledger=receipts['fixture-ledger.json'];events=ledger['events'];samples=[receipts['webrtc-custody-'+p+'.json'] for p in PHASES]
        before,success,direct,repeat=samples;cleanup=receipts['webrtc-custody-cleanup.json']
        require(before['manager']['pid']==state['managerPID'] and before['managerSHA256']==state['managerSHA256']
                and before['candidateManifestSHA256']==state['candidateManifestSHA256']
                and before['profileID']==state['profiles'][0]['id'].lower()
                and before['directBaseline']['profileID']==state['profiles'][1]['id'].lower()
                and before['version']==state['version'] and str(before['build'])==str(state['build']),'current-state-binding-differs')
        for key in ('fixtureSHA256','webrtcFixtureSHA256','webrtcProbeSHA256'):
            require(before[key]==state[key],'current-fixture-state-differs')
        require(ledger['serverThreadsDrained'] is True and type(ledger['managerExitCode']) is int and ledger['managerExitCode']==0
                and ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining']==0 and ledger['runtimeCleanup']['signaledMainProcesses']==0,'cleanup-not-settled')
        require(isinstance(events,list) and 0<len(events)<=4096 and all(isinstance(e,dict) and number(e['at']) for e in events)
                and [e['at'] for e in events]==sorted(e['at'] for e in events),'invalid-ledger')
        require(all(s['phase']==p and number(s['at']) for s,p in zip(samples,PHASES))
                and [s['at'] for s in samples]==sorted(set(s['at'] for s in samples)),'custody-order-differs')
        for sample in samples:
            process(sample['manager'])
            require(sample['manager']==before['manager'] and sample['managerSHA256']==release['managerSHA256']
                    and sample['version']==release['version'] and str(sample['build'])==str(release['build']),'manager-binding-differs')
            for key in (*HASHES,'candidateManifestSHA256'):require(digest(sample[key]) and sample[key]==before[key],'source-binding-differs')
        prefs={'webrtc':{'ip_handling_policy':'default','ip_handling_url':[{'url':'http://127.0.0.1:*','handling':'default'}],
                         'local_ips_allowed_urls':['http://127.0.0.1:*']}}
        attempted=[e for e in events if e['kind']=='webrtc-permissive-user-prefs'];require(len(attempted)==1,'attempted-prefs-missing')
        require(before['attemptedUserPreferences']==prefs==attempted[0]['preferences'] and attempted[0]['profileID']==before['profileID']
                and digest(before['attemptedUserPreferencesSHA256']) and before['attemptedUserPreferencesSHA256']==attempted[0]['preferencesSHA256'],'attempted-prefs-differ')
        for sample in (success,repeat):
            for key in ('browser','relayOwner'):process(sample[key])
            for key in ('browser','relayOwner','relay','profileID','revision','metadataIdentitySHA256','updatedAt',
                        'lastLaunchedAt','sessionGeneration','leaseSHA256','configurationSHA256'):require(sample[key]==success[key],'protected-session-changed')
            relay=sample['relay']
            require(sample['profileID']==before['profileID'] and sample['observedWebRTCPolicy']=='disable_non_proxied_udp'
                    and relay['profileID'].lower()==sample['profileID'] and relay['sessionGeneration'].lower()==sample['sessionGeneration']
                    and relay['configurationSHA256']==sample['configurationSHA256'] and digest(sample['leaseSHA256'])
                    and digest(sample['configurationSHA256']),'protected-policy-lease-differs')
            require(sample['browser']['parentPID']==sample['relayOwner']['parentPID']==before['manager']['pid']
                    and relay['ownerPID']==sample['relayOwner']['pid'] and relay['ownerStartSeconds']==sample['relayOwner']['startSeconds']
                    and relay['ownerStartMicroseconds']==sample['relayOwner']['startMicroseconds'] and relay['ownerUID']==sample['relayOwner']['uid'],'relay-generation-differs')
            require(relay['runtimeExecutableSHA256']==release['runtime']['executableSHA256'] and relay['runtimeFrameworkSHA256']==release['runtime']['frameworkSHA256'],'relay-runtime-differs')
        process(direct['browser'])
        require(direct['profileID']==before['directBaseline']['profileID'] and direct['profileID']!=success['profileID']
                and direct.get('relay') is None and direct['browser']['pid']!=success['browser']['pid']
                and direct['browser']['parentPID']==before['manager']['pid'] and direct['observedWebRTCPolicy']=='default_public_interface_only','direct-control-differs')
        for sample in (success,direct,repeat):
            require(sample['runtimeExecutableSHA256']==release['runtime']['executableSHA256']
                    and sample['runtimeFrameworkSHA256']==release['runtime']['frameworkSHA256'],'runtime-binding-differs')
        for index,sample in enumerate((success,direct,repeat)):
            phase=sample['phase'];protected=phase!='direct-control';low=samples[index]['at'];high=sample['at']
            wanted=lambda kind:[e for e in events if e['kind']==kind and e.get('phase')==phase]
            controls,pages,probes,finals=[wanted(kind) for kind in ('webrtc-stun-control','webrtc-page','webrtc-probe','webrtc-stun-final')]
            require(all(len(group)==1 for group in (controls,pages,probes,finals)),'phase-observations-missing-or-duplicated')
            control,page,probe,final=controls[0],pages[0],probes[0],finals[0]
            require(low<control['at']<=page['at']<probe['at']<=high<final['at']<cleanup['at'],'phase-window-differs')
            require(control['canaryAcknowledged'] is True and control['resetVerified'] is True
                    and type(control['canaryCount']) is int and control['canaryCount']==1
                    and type(control['countAfterReset']) is int and control['countAfterReset']==0,'collector-positive-missing')
            require(page['throughOwnedUpstream'] is protected and probe['throughOwnedUpstream'] is protected,'http-route-differs')
            result=probe['probe']
            require(set(result)=={'gatheringComplete','iceGatheringState','timedOut','candidates','errorCodes','rawICEExported'}
                    and result['gatheringComplete'] is True and result['iceGatheringState']=='complete'
                    and result['timedOut'] is False and result['rawICEExported'] is False,'incomplete-ICE-not-PASS')
            require(set(result['candidates'])=={'host','srflx','prflx','relay','other'} and all(count(v) for v in result['candidates'].values())
                    and isinstance(result['errorCodes'],list) and len(result['errorCodes'])<=16 and all(count(v) for v in result['errorCodes']),'invalid-probe-values')
            require(final['closed'] is True and final['threadDrained'] is True and type(final['canaryCount']) is int and final['canaryCount']==1
                    and type(final['invalidRequests']) is int and final['invalidRequests']==0 and count(final['browserRequests']),'final-UDP-counters-missing')
            require(final['browserRequests']==0 if protected else final['browserRequests']>0,'UDP-boundary-differs')
            for event,is_receipt in ((page,False),(probe,True)):
                if protected:
                    require(event['peer']['throughOwnedFixture'] is True and digest(event['peer']['requestIDSHA256']),'request-link-missing')
                    peers=[e for e in wanted('webrtc-upstream-peer') if e['isReceipt'] is is_receipt and e['requestIDSHA256']==event['peer']['requestIDSHA256']]
                    require(peers and all(low<e['at']<event['at'] for e in peers),'live-relay-request-custody-missing')
                    for peer in peers:peer_matches(peer,sample,True)
                else:peer_matches(event['peer'],sample,False)
            if not protected:
                peers=wanted('webrtc-udp-peer');require(len(peers)==final['browserRequests'],'UDP-source-attribution-missing')
                for peer in peers:
                    require(page['at']<peer['at']<probe['at'],'UDP-outside-page-window');peer_matches(peer,sample,False)
        require(not any(e['kind']=='webrtc-protected-udp' for e in events),'protected-UDP-observed')
        require(type(cleanup['ownedProcessesRemaining']) is int and cleanup['ownedProcessesRemaining']==0
                and cleanup['ordinaryInstanceTouched'] is False and cleanup['collectorSHA256']==before['webrtcCollectorSHA256'],'owned-cleanup-missing')
        exits=cleanup['browserExitObservations'];require(isinstance(exits,list) and len(exits)==2,'browser-exit-records-missing')
        require(sorted(e['profileID'] for e in exits)==sorted([success['profileID'],direct['profileID']]),'browser-exit-profiles-differ')
        for event in exits:
            require(digest(event['logSHA256']) and type(event['launchCount']) is int and event['launchCount']==1
                    and type(event['terminationReason']) is int and event['terminationReason']==1
                    and type(event['terminationStatus']) is int and event['terminationStatus']==0,'browser-crash-or-exit-unknown')
    except (KeyError,TypeError,IndexError,AttributeError):raise ValueError('missing-or-malformed-webrtc-evidence') from None
    diagnostics=[dict(kind=e['kind'],at=e['at']) for e in events if e['kind'] in ('webrtc-origin-refused','proxy-operation-failure')]
    return dict(schemaVersion=1,result='scoped-manager-relay-webrtc-observations-pass',version=release['version'],build=release['build'],
                checks=['normal headed manager/relay launch, no CDP','permissive user prefs plus strict effective CLI guard','complete ICE and zero protected UDP',
                        'real manager Direct STUN positive with live UDP source-owner chain','nonce completion linked to live TCP custody',
                        'unchanged protected browser/relay/session/config on repeat','final counters and owned process drain without fixture signals',
                        'both browser main processes: signed manager records normal exit/status0'],
                HTTPDiagnostics=diagnostics,allHTTPCleanQualified=False,
                diagnosticBoundary='Unclassified refused HTTP connections retained; no inference that native requests were favicons. They cannot replace any required nonce/ICE/socket/UDP observation.',
                gracefulCloseQualified=False,globalNetworkQualified=False,allPoint21GatesComplete=False,releaseGate=False,
                limitation='Own loopback UDP4 and HTTP-auth relay only; OS managed policy, IPv6/TURN, external interfaces and network transition remain open')


def analyze(directory,release):
    state,_=W.owned_state(directory/'private-state.json');receipts={name:W.CORE.load(directory/name) for name in INPUTS}
    for key,name in HASHES.items():
        actual=W.CORE.sha(Path(__file__).with_name(name).read_bytes())
        require(all(receipts['webrtc-custody-'+phase+'.json'][key]==actual for phase in PHASES),'source-drift')
    result=qualify(receipts,release,state);result['inputSHA256']={name:W.CORE.sha(W.CORE.read_private(directory/name)) for name in INPUTS}
    result['analyzerSHA256']=W.CORE.sha(Path(__file__).read_bytes());return result


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--receipts',type=Path,required=True);parser.add_argument('--release',type=Path,required=True);args=parser.parse_args()
    try:result=analyze(args.receipts,json.loads(args.release.read_bytes()))
    except (ValueError,OSError):parser.exit(1,'Manager WebRTC evidence refused.\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
