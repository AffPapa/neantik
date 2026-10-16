import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]/'runtime-network'
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
TCP=module('tcp_analysis_test','analyze-manager-tcp.py')
AX=module('tcp_ax_test','observe-manager-tcp-failure.py')


class ManagerTCPAnalysisTests(unittest.TestCase):
    def fixture(self):
        process=lambda pid,parent:dict(pid=pid,parentPID=parent,uid=501,startSeconds=10,startMicroseconds=123,cdhash='a'*40)
        manager,browser,owner,direct_browser=process(101,1),process(102,101),process(103,101),process(104,101)
        relay=dict(profileID='aaa',sessionGeneration='sessiona',configurationSHA256='c'*64,
                   runtimeExecutableSHA256='d'*64,runtimeFrameworkSHA256='e'*64,
                   ownerPID=103,ownerStartSeconds=10,ownerStartMicroseconds=123,ownerUID=501)
        common={**{key:'b'*64 for key in TCP.HASHES},'manager':manager,'managerSHA256':'f'*64,
                'version':'0.8.21','build':'133','candidateManifestSHA256':'1'*64}
        baseline=dict(common,phase='before-launch',at=1,profileID='aaa',directBaseline={'profileID':'bbb'})
        success=dict(common,phase='proxy-success',at=2,profileID='aaa',browser=browser,relayOwner=owner,relay=relay,
                     revision=4,metadataIdentitySHA256='2'*64,updatedAt='now',lastLaunchedAt='now',
                     sessionGeneration='sessiona',leaseSHA256='3'*64,configurationSHA256='c'*64)
        refused=dict(success,phase='listener-refused',at=4.5)
        direct=dict(common,phase='direct-control',at=11,profileID='bbb',browser=direct_browser,
                    sessionGeneration='sessionb',leaseSHA256='4'*64)
        recovered=dict(success,phase='proxy-recovered',at=14)
        def event(kind,at,**kw):return dict(kind=kind,at=at,**kw)
        def peer(at,direct_route=False):
            return event('tcp-direct-peer' if direct_route else 'tcp-request-peer',at,
                         phase='direct-control' if direct_route else None,manager=manager,
                         browser=direct_browser if direct_route else browser,profileID='bbb' if direct_route else 'aaa',
                         sessionGeneration='sessionb' if direct_route else 'sessiona',
                         configurationSHA256=None if direct_route else 'c'*64,socketTupleSHA256='5'*64,
                         peerChain=[direct_browser] if direct_route else [owner])
        def origin(at,phase,epoch,active,protected):
            return event('tcp-origin-arrival',at,phase=phase,faultEpoch=epoch,listenerActive=active,throughOwnedUpstream=protected)
        events=[event('tcp-listener-control',0,faultEpoch=0,listenerActive=True),peer(1.3),
                origin(1.5,'proxy-success',0,True,True),event('origin',1.6,phase='proxy-success',throughOwnedUpstream=True),
                event('tcp-listener-control',3,faultEpoch=1,listenerActive=False,socketProbeRefused=True),
                origin(10.5,'direct-control',1,False,False),peer(10.6,True),event('origin',10.7,phase='direct-control',throughOwnedUpstream=False),
                event('tcp-listener-control',12,faultEpoch=2,listenerActive=True,sameEndpoint=True),peer(12.4),
                origin(13,'proxy-recovered',2,True,True),event('origin',13.1,phase='proxy-recovered',throughOwnedUpstream=True)]
        state={'urls':{'listener-refused':'http://owned.test/fixture?nonce=synthetic'}}
        failure=dict(schemaVersion=1,phase='listener-refused',at=4,browser=browser,leaseSHA256='3'*64,
                     configurationSHA256='c'*64,expectedURLSHA256=hashlib.sha256(state['urls']['listener-refused'].encode()).hexdigest(),
                     errorCode='ERR_SOCKS_CONNECTION_FAILED',observerSHA256='6'*64,
                     observationMethod='operator-owned-CUA-AX',reducedAXSHA256='7'*64)
        receipts={'fixture-ledger.json':dict(events=events,serverThreadsDrained=True,managerExitCode=0,
                                           runtimeCleanup={'ownedRuntimeProcessesRemaining':0}),
                  'tcp-browser-failure.json':failure,
                  'tcp-custody-cleanup.json':dict(at=15,ownedProcessesRemaining=0,ordinaryInstanceTouched=False,collectorSHA256='b'*64)}
        for value in [baseline,success,refused,direct,recovered]:receipts['tcp-custody-'+value['phase']+'.json']=copy.deepcopy(value)
        release=dict(version='0.8.21',build=133,managerSHA256='f'*64,runtime={'executableSHA256':'d'*64,'frameworkSHA256':'e'*64})
        return receipts,release,state

    def test_complete_model_is_bounded_not_global_network_pass(self):
        result=TCP.qualify(*self.fixture())
        self.assertEqual(result['result'],'scoped-physical-tcp-observations-pass')
        self.assertFalse(result['releaseGate']);self.assertFalse(result['allNetworkGatesComplete'])
        self.assertFalse(result['globalDNSQualified'])

    def test_missing_and_mutated_native_controls_fail(self):
        changes=[
            lambda r:r.pop('tcp-browser-failure.json'),
            lambda r:r['tcp-browser-failure.json'].update(observationMethod='unattested-boolean'),
            lambda r:r['tcp-browser-failure.json'].update(reducedAXSHA256='invalid'),
            lambda r:r['tcp-browser-failure.json'].update(errorCode='ERR_NAME_NOT_RESOLVED'),
            lambda r:r['tcp-browser-failure.json'].update(expectedURLSHA256='0'*64),
            lambda r:r['tcp-browser-failure.json'].update(at=2),
            lambda r:r['tcp-browser-failure.json'].update(leaseSHA256='0'*64),
            lambda r:r['tcp-custody-listener-refused.json']['browser'].update(pid=999),
            lambda r:r['tcp-custody-proxy-recovered.json'].update(configurationSHA256='0'*64),
            lambda r:r['tcp-custody-proxy-recovered.json'].update(revision=10),
            lambda r:r['tcp-custody-proxy-success.json'].update(managerSHA256='0'*64),
            lambda r:r['tcp-custody-proxy-recovered.json']['relay'].update(runtimeFrameworkSHA256='0'*64),
            lambda r:r['tcp-custody-direct-control.json'].update(relay={}),
            lambda r:r['tcp-custody-direct-control.json']['browser'].update(pid=102),
            lambda r:r['tcp-custody-direct-control.json'].update(at=8),
            lambda r:r['tcp-custody-cleanup.json'].update(ownedProcessesRemaining=1),
            lambda r:r['tcp-custody-cleanup.json'].update(ownedProcessesRemaining=False),
            lambda r:r['fixture-ledger.json'].update(serverThreadsDrained=False),
            lambda r:r['fixture-ledger.json'].update(managerExitCode=True),
            lambda r:r['fixture-ledger.json']['runtimeCleanup'].update(ownedRuntimeProcessesRemaining=False),
        ]
        for index,change in enumerate(changes):
            r,release,state=self.fixture();change(r)
            with self.subTest(index=index),self.assertRaises(ValueError):TCP.qualify(r,release,state)

    def test_ledger_negative_controls_detect_bypass_and_false_refusal(self):
        def pick(r,kind):return next(e for e in r['fixture-ledger.json']['events'] if e['kind']==kind)
        changes=[
            lambda r:pick(r,'tcp-request-peer').update(peerChain=[]),
            lambda r:pick(r,'tcp-request-peer').update(configurationSHA256='0'*64),
            lambda r:pick(r,'tcp-direct-peer').update(sessionGeneration='wrong'),
            lambda r:pick(r,'tcp-origin-arrival').update(throughOwnedUpstream=False),
            lambda r:r['fixture-ledger.json']['events'][4].update(socketProbeRefused=False),
            lambda r:r['fixture-ledger.json']['events'][8].update(sameEndpoint=False),
            lambda r:r['fixture-ledger.json']['events'][4].update(listenerActive=True),
            lambda r:r['fixture-ledger.json']['events'].insert(5,dict(kind='tcp-origin-arrival',at=3.5,phase='listener-refused',faultEpoch=1,listenerActive=False,throughOwnedUpstream=False)),
            lambda r:r['fixture-ledger.json']['events'].insert(5,dict(kind='tcp-origin-arrival',at=3.5,phase='listener-refused',faultEpoch=1,listenerActive=False,throughOwnedUpstream=True)),
            lambda r:r['fixture-ledger.json']['events'].pop(3),
        ]
        for index,change in enumerate(changes):
            r,release,state=self.fixture();change(r)
            with self.subTest(index=index),self.assertRaises(ValueError):TCP.qualify(r,release,state)

    def test_ax_requires_exact_nonce_url_and_supported_error(self):
        url='http://127.0.0.1:12345/owned-route?nonce=synthetic'
        self.assertEqual(AX.reduce_values(url+'\nERR_SOCKS_CONNECTION_FAILED',url),'ERR_SOCKS_CONNECTION_FAILED')
        self.assertEqual(AX.reduce_values(url.removeprefix('http://')+'\nERR_PROXY_CONNECTION_FAILED',url),'ERR_PROXY_CONNECTION_FAILED')
        for text in ['ERR_SOCKS_CONNECTION_FAILED','http://other.test/\nERR_SOCKS_CONNECTION_FAILED',url+'\nERR_NAME_NOT_RESOLVED',url+'\nERR_SOCKS_CONNECTION_FAILED ERR_PROXY_CONNECTION_FAILED','x'*65537]:
            with self.subTest(case=len(text)),self.assertRaises(ValueError):AX.reduce_values(text,url)


if __name__=='__main__':unittest.main()
