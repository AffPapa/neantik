"""Synthetic joins prove analyzer sensitivity; they never qualify a browser."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC=importlib.util.spec_from_file_location('webrtc_analysis_tests',Path(__file__).resolve().parents[1]/'runtime-network/analyze-manager-webrtc.py')
M=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(M)


def fixture():
    process=lambda pid,parent:dict(pid=pid,parentPID=parent,uid=501,startSeconds=1,startMicroseconds=2,cdhash='a'*40)
    manager=process(10,1);browser=process(20,10);relay_owner=process(21,10);direct_browser=process(30,10);helper=process(31,30)
    profile='11111111-1111-4111-8111-111111111111';direct_id='22222222-2222-4222-8222-222222222222'
    relay=dict(profileID=profile,sessionGeneration='session',configurationSHA256='e'*64,ownerPID=21,ownerStartSeconds=1,ownerStartMicroseconds=2,
               ownerUID=501,runtimeExecutableSHA256='1'*64,runtimeFrameworkSHA256='2'*64)
    release=dict(version='0.8.21',build=133,managerSHA256='b'*64,runtime=dict(executableSHA256='1'*64,frameworkSHA256='2'*64))
    common=dict(manager=manager,managerSHA256='b'*64,version='0.8.21',build='133',profileID=profile,revision=2,metadataIdentitySHA256='f'*64,
                lastLaunchedAt='own',updatedAt='own',candidateManifestSHA256='d'*64,**{key:'c'*64 for key in M.HASHES})
    before=dict(common,phase='before-launch',at=10,directBaseline=dict(profileID=direct_id,revision=0,metadataIdentitySHA256='f'*64),
                attemptedUserPreferences={'webrtc':{'ip_handling_policy':'default','ip_handling_url':[{'url':'http://127.0.0.1:*','handling':'default'}],
                                                  'local_ips_allowed_urls':['http://127.0.0.1:*']}},attemptedUserPreferencesSHA256='9'*64)
    protected=dict(common,browser=browser,relayOwner=relay_owner,relay=relay,sessionGeneration='session',leaseSHA256='d'*64,
                   configurationSHA256='e'*64,observedWebRTCPolicy='disable_non_proxied_udp',runtimeExecutableSHA256='1'*64,runtimeFrameworkSHA256='2'*64)
    success=dict(protected,phase='proxy-success',at=20);repeat=dict(protected,phase='proxy-repeat',at=40)
    direct=dict(common,phase='direct-control',at=30,profileID=direct_id,browser=direct_browser,sessionGeneration='direct',leaseSHA256='8'*64,
                observedWebRTCPolicy='default_public_interface_only',runtimeExecutableSHA256='1'*64,runtimeFrameworkSHA256='2'*64)
    samples=[before,success,direct,repeat]
    events=[dict(kind='webrtc-permissive-user-prefs',at=1,profileID=profile,preferences=before['attemptedUserPreferences'],preferencesSHA256='9'*64)]
    for i,sample in enumerate((success,direct,repeat)):
        phase=sample['phase'];start=11+i*10;guarded=phase!='direct-control'
        peer=dict(manager=manager,browser=sample['browser'],profileID=sample['profileID'],sessionGeneration=sample['sessionGeneration'],
                  socketTupleSHA256='7'*64,peerChain=[relay_owner] if guarded else [helper,direct_browser],configurationSHA256='e'*64 if guarded else None)
        events.append(dict(kind='webrtc-stun-control',at=start,phase=phase,canaryAcknowledged=True,resetVerified=True,canaryCount=1,countAfterReset=0))
        result=dict(gatheringComplete=True,iceGatheringState='complete',timedOut=False,candidates=dict(host=0,srflx=0,prflx=0,relay=0,other=0),errorCodes=[],rawICEExported=False)
        for kind,offset,receipt,request_hash in [('webrtc-page',1,False,str(1+i*2)*64),('webrtc-probe',3,True,str(2+i*2)*64)]:
            event=dict(kind=kind,at=start+offset,phase=phase,throughOwnedUpstream=guarded,
                       peer=dict(throughOwnedFixture=True,requestIDSHA256=request_hash) if guarded else peer)
            if receipt:event['probe']=result
            events.append(event)
            if guarded:events.append(dict(kind='webrtc-upstream-peer',at=start+offset-.5,phase=phase,isReceipt=receipt,requestIDSHA256=request_hash,**peer))
        if not guarded:events.append(dict(kind='webrtc-udp-peer',at=start+2,phase=phase,**peer))
        events.append(dict(kind='webrtc-stun-final',at=45+i,phase=phase,closed=True,threadDrained=True,canaryCount=1,invalidRequests=0,browserRequests=0 if guarded else 1))
    events.sort(key=lambda e:e['at'])
    receipts={'fixture-ledger.json':dict(events=events,serverThreadsDrained=True,managerExitCode=0,runtimeCleanup=dict(ownedRuntimeProcessesRemaining=0,signaledMainProcesses=0)),
              **{'webrtc-custody-'+s['phase']+'.json':s for s in samples},
              'webrtc-custody-cleanup.json':dict(at=60,ownedProcessesRemaining=0,ordinaryInstanceTouched=False,collectorSHA256='c'*64,
                 browserExitObservations=[dict(profileID=pid,logSHA256='a'*64,launchCount=1,terminationReason=1,terminationStatus=0) for pid in (profile,direct_id)])}
    # Independently captured files do not share Python object aliases.
    state=dict(managerPID=10,managerSHA256='b'*64,candidateManifestSHA256='d'*64,profiles=[dict(id=profile),dict(id=direct_id)],
               version=release['version'],build=release['build'],**{key:'c'*64 for key in ('fixtureSHA256','webrtcFixtureSHA256','webrtcProbeSHA256')})
    return {name:copy.deepcopy(value) for name,value in receipts.items()},release,state


class ManagerWebRTCAnalysisTests(unittest.TestCase):
    def diagnostic(self,kind,at=1,correlation='a'*64):
        return dict(kind=kind,at=at,diagnosticVersion=1,stage='nonce-validation',requestCategory='favicon',
                    failureCategory='protocol',originConnectionSHA256=correlation)

    def test_diagnostic_hints_never_establish_route_cause_or_erase_legacy_unknowns(self):
        events=[dict(kind='proxy-operation-failure',at=1),
                self.diagnostic('proxy-operation-failure',2),self.diagnostic('webrtc-origin-refused',2.1)]
        events[1]['privateHeader']='not-to-export'
        result=M.summarize_http_diagnostics(events)
        self.assertEqual(result['entries'][0]['classification'],'unclassified')
        self.assertEqual(len(result['uniqueSocketHints']),1)
        self.assertFalse(result['causeEstablished']);self.assertFalse(result['browserCustodyEstablished'])
        self.assertFalse(result['allHTTPCleanQualified'])
        self.assertNotIn('not-to-export',str(result))
        receipts,release,state=fixture();receipts['fixture-ledger.json']['events']+=events
        receipts['fixture-ledger.json']['events'].sort(key=lambda e:e['at'])
        joined=M.qualify(receipts,release,state)
        self.assertFalse(joined['allHTTPCleanQualified']);self.assertFalse(joined['releaseGate'])
        self.assertEqual(joined['HTTPDiagnosticSummary']['entries'][0]['classification'],'unclassified')

    def test_reused_unpaired_and_distant_tuple_hashes_are_not_unique_hints(self):
        a=self.diagnostic('proxy-operation-failure',1);b=self.diagnostic('webrtc-origin-refused',1.1)
        for events in ([a],[a,b,self.diagnostic('webrtc-origin-refused',1.2)],
                       [a,self.diagnostic('webrtc-origin-refused',4)],
                       [a,self.diagnostic('proxy-operation-failure',1.1)]):
            result=M.summarize_http_diagnostics(events)
            self.assertFalse(result['uniqueSocketHints']);self.assertEqual(result['ambiguousOrUnpairedGroups'],1)

    def test_diagnostic_unknown_fields_types_and_partial_metadata_are_refused(self):
        for key,value in [('diagnosticVersion',True),('stage','private text'),('requestCategory','/private'),
                          ('failureCategory','raw-exception'),('originConnectionSHA256','raw-peer'),('at',True)]:
            event=self.diagnostic('proxy-operation-failure');event[key]=value
            with self.assertRaises(ValueError):M.summarize_http_diagnostics([event])
        event=self.diagnostic('proxy-operation-failure');del event['stage']
        with self.assertRaises(ValueError):M.summarize_http_diagnostics([event])

    def test_complete_model_has_explicit_scope(self):
        result=M.qualify(*fixture());self.assertEqual(result['result'],'scoped-manager-relay-webrtc-observations-pass')
        self.assertFalse(result['allPoint21GatesComplete']);self.assertFalse(result['releaseGate'])

    def test_contradictory_evidence_is_rejected(self):
        mutations=[
            lambda r:r['fixture-ledger.json'].update(managerExitCode=1),
            lambda r:r['fixture-ledger.json']['runtimeCleanup'].update(signaledMainProcesses=1),
            lambda r:r['fixture-ledger.json'].update(serverThreadsDrained=False),
            lambda r:r['webrtc-custody-proxy-repeat.json']['browser'].update(startSeconds=2),
            lambda r:r['webrtc-custody-proxy-repeat.json'].update(leaseSHA256='a'*64),
            lambda r:r['webrtc-custody-direct-control.json'].update(observedWebRTCPolicy='disable_non_proxied_udp'),
            lambda r:r['webrtc-custody-proxy-success.json'].update(observedWebRTCPolicy='default'),
            lambda r:r['webrtc-custody-proxy-repeat.json'].update(runtimeFrameworkSHA256='0'*64),
            lambda r:r['webrtc-custody-before-launch.json']['attemptedUserPreferences']['webrtc'].update(ip_handling_policy='disable_non_proxied_udp'),
            lambda r:r['webrtc-custody-cleanup.json'].update(ownedProcessesRemaining=1),
            lambda r:r['webrtc-custody-cleanup.json']['browserExitObservations'][0].update(terminationReason=2),
            lambda r:r['webrtc-custody-cleanup.json']['browserExitObservations'][0].update(terminationStatus=15),
            lambda r:r['webrtc-custody-cleanup.json'].update(browserExitObservations=[]),
        ]
        event_mutations=[('webrtc-probe',lambda e:e['probe'].update(gatheringComplete=False)),
                         ('webrtc-probe',lambda e:e['probe'].update(timedOut=True)),
                         ('webrtc-probe',lambda e:e['probe'].update(rawICEExported=True)),
                         ('webrtc-stun-control',lambda e:e.update(canaryAcknowledged=False)),
                         ('webrtc-stun-control',lambda e:e.update(countAfterReset=1)),
                         ('webrtc-stun-final',lambda e:e.update(browserRequests=1)),
                         ('webrtc-stun-final',lambda e:e.update(invalidRequests=1)),
                         ('webrtc-stun-final',lambda e:e.update(closed=False)),
                         ('webrtc-upstream-peer',lambda e:e.update(requestIDSHA256='0'*64)),
                         ('webrtc-upstream-peer',lambda e:e.update(configurationSHA256='0'*64)),
                         ('webrtc-upstream-peer',lambda e:e.update(peerChain=[])),
                         ('webrtc-page',lambda e:e.update(throughOwnedUpstream=False))]
        for kind,mutate in event_mutations:
            mutations.append(lambda r,k=kind,f=mutate:f(next(e for e in r['fixture-ledger.json']['events'] if e['kind']==k and e['phase']=='proxy-success')))
        for mutate in mutations:
            receipts,release,state=copy.deepcopy(fixture());mutate(receipts)
            with self.subTest(mutation=mutations.index(mutate)),self.assertRaises(ValueError):M.qualify(receipts,release,state)

    def test_missing_or_unattributed_direct_positive_and_duplicated_completion_fail(self):
        for kind in ('webrtc-udp-peer','webrtc-probe','webrtc-stun-control','webrtc-page'):
            receipts,release,state=fixture();events=receipts['fixture-ledger.json']['events'];events[:]=[e for e in events if not (e['kind']==kind and e['phase']=='direct-control')]
            with self.assertRaises(ValueError):M.qualify(receipts,release,state)
        receipts,release,state=fixture();events=receipts['fixture-ledger.json']['events'];event=copy.deepcopy(next(e for e in events if e['kind']=='webrtc-probe'));events.append(event);events.sort(key=lambda e:e['at'])
        with self.assertRaises(ValueError):M.qualify(receipts,release,state)

    def test_receipts_cannot_be_replayed_with_another_current_state(self):
        for field,value in [('candidateManifestSHA256','0'*64),('managerSHA256','0'*64),('managerPID',99),
                            ('webrtcFixtureSHA256','0'*64),('version','other'),('build',999)]:
            receipts,release,state=fixture();state[field]=value
            with self.assertRaises(ValueError):M.qualify(receipts,release,state)
        receipts,release,state=fixture();state['profiles'][0]['id']='33333333-3333-4333-8333-333333333333'
        with self.assertRaises(ValueError):M.qualify(receipts,release,state)

    def test_unclassified_HTTP_diagnostics_never_replace_required_evidence(self):
        receipts,release,state=fixture();events=receipts['fixture-ledger.json']['events']
        events.extend([dict(kind='proxy-operation-failure',at=12.1),dict(kind='webrtc-origin-refused',at=12.2)])
        events.sort(key=lambda e:e['at']);result=M.qualify(receipts,release,state)
        self.assertEqual(len(result['HTTPDiagnostics']),2);self.assertFalse(result['allHTTPCleanQualified'])
        damaged=copy.deepcopy(receipts);next(e for e in damaged['fixture-ledger.json']['events'] if e['kind']=='webrtc-probe')['probe']['gatheringComplete']=False
        with self.assertRaises(ValueError):M.qualify(damaged,release,state)
        damaged=copy.deepcopy(receipts);damaged['fixture-ledger.json']['events'].append(dict(kind='webrtc-protected-udp',at=12.3))
        damaged['fixture-ledger.json']['events'].sort(key=lambda e:e['at'])
        with self.assertRaises(ValueError):M.qualify(damaged,release,state)


if __name__=='__main__':unittest.main()
