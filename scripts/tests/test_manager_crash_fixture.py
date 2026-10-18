"""Protocol, custody refusal and actual-receipt analysis controls; not native PASS."""
import copy
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1] / 'runtime-network'
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file); value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
F=module('crash_fixture_test','manager-crash-fixture.py')
A=module('crash_analysis_test','analyze-manager-crash.py')
C=A.C
H='a'*64


def result(phase,baseline='base',fresh='fresh'):
    empty={k:None for k in F.STORES}; old={k:baseline for k in F.STORES}; new={k:fresh for k in F.STORES}
    first=dict(baseline=empty,fresh=empty,aborted=None,sessionStorage=None)
    settled=dict(baseline=old,fresh=empty,aborted=None,sessionStorage=None)
    changed=dict(baseline=old,fresh=new,aborted=None,sessionStorage=fresh)
    before,after=(first,settled) if phase=='baseline' else ((settled,changed) if phase=='mutate' else (changed,changed))
    return dict(phase=phase,before=copy.deepcopy(before),after=copy.deepcopy(after),wrote=phase!='read',
                strictCompleted=phase!='read',abortedAfterRequestSuccess=phase=='mutate',errors=[])


def model():
    manager=dict(pid=10,parentPID=2,uid=501,startSeconds=100,startMicroseconds=1,cdhash='b'*40)
    samples=[]
    state=dict(managerPID=10,managerSHA256=H,candidateManifestSHA256=H,version='own',build='1',profiles=[{},dict(id='own')],**{k:H for k in ('fixtureSHA256','crashFixtureSHA256','crashProbeSHA256','peerCollectorSHA256')})
    release=dict(version='own',build='1',managerSHA256=H,runtime=dict(executableSHA256=H,frameworkSHA256=H))
    for i,(stage,at) in enumerate(zip(C.LIVE_STAGES,(3,8,25))):
        browser=dict(pid=11+i,parentPID=10,uid=501,startSeconds=101+i,startMicroseconds=1,cdhash='b'*40)
        samples.append(dict(at=at,crashStage=stage,phase='direct-control',manager=manager,browser=browser,profileID='own',metadataIdentitySHA256=H,
            managerSHA256=H,candidateManifestSHA256=H,version='own',build='1',runtimeExecutableSHA256=H,runtimeFrameworkSHA256=H,
            sessionGeneration='s'+str(i),leaseSHA256=H,revision=i+1,lastLaunchedAt=str(i),updatedAt=str(i),**{k:H for k in A.HASHES}))
        samples[-1]['runtimeProcesses']=[dict(identity=browser,executable='/own/browser')]
    events=[]
    for sample,phase,at in zip(samples,C.LIVE_STAGES,(1,6,23)):
        peer=dict(manager=manager,browser=sample['browser'],profileID='own',sessionGeneration=sample['sessionGeneration'],peerChain=[sample['browser']],socketTupleSHA256=H)
        events.extend([dict(kind='crash-page',phase=phase,at=at,peer=copy.deepcopy(peer)),
                       dict(kind='crash-result',at=at+1,peer=copy.deepcopy(peer),**F.validate_result(result(phase),phase,'base','fresh'))])
    intent=dict(at=10,signal=9,target=samples[1]['browser'],manager=manager,custody=copy.deepcopy(samples[1]),
                descendants=[dict(identity=samples[1]['browser'],executable='/own/browser')],collectorSHA256=H)
    receipts={**{'crash-custody-'+s+'.json':v for s,v in zip(C.LIVE_STAGES,samples)},'crash-intent.json':intent,
        'crash-signal.json':dict(at=11,signal=9,issued=True,target=samples[1]['browser'],processGroupSignaled=False,ordinaryInstanceTouched=False,collectorSHA256=H),
        'crash-after.json':dict(at=20,manager=manager,signal=9,mainGenerationAbsent=True,capturedDescendantsAbsent=True,capturedDescendantCount=1,
                              leaseRetired=True,dataOpenFiles=0,observedExits=[dict(reason=1,status=0),dict(reason=2,status=9)],collectorSHA256=H),
        'crash-cleanup.json':dict(at=30,ownedProcessesRemaining=0,capturedGenerationsAbsent=True,leaseAbsent=True,ordinaryInstanceTouched=False,
                                logSHA256=H,observedExits=[dict(reason=1,status=0),dict(reason=2,status=9),dict(reason=1,status=0)],collectorSHA256=H),
        'fixture-ledger.json':dict(managerExitCode=0,serverThreadsDrained=True,runtimeCleanup=dict(ownedRuntimeProcessesRemaining=0,signaledMainProcesses=0),events=events),
        'crash-ui.json':dict(source='native-cua-operator-reduction',managerPID=10,profileID='own',**{k:True for k in A.UI_FLAGS})}
    return receipts,release,state


class CrashProtocolTests(unittest.TestCase):
    def test_all_phases_and_fresh_async_store_losses_are_distinguished(self):
        for phase in F.PHASES:
            self.assertTrue(F.validate_result(result(phase),phase,'base','fresh')['baselineIntact'])
        for key in ('cookie','localStorage','cacheStorage'):
            value=result('read');value['before']['fresh'][key]=value['after']['fresh'][key]=None
            self.assertFalse(F.validate_result(value,'read','base','fresh')['freshPresence'][key])
        value=result('read');value['before']['sessionStorage']=value['after']['sessionStorage']=None
        self.assertFalse(F.validate_result(value,'read','base','fresh')['sessionRestored'])

    def test_lost_baseline_acknowledged_idb_or_committed_aborted_value_refuse(self):
        for phase in F.PHASES:
            changes=[lambda v:v.update(secret='forbidden'),lambda v:v.update(errors=['timeout']),lambda v:v.update(wrote=not v['wrote']),
                     lambda v:v['after'].update(aborted='fresh'),lambda v:v['after']['baseline'].update(cookie=None)]
            if phase!='baseline':changes.append(lambda v:v['after']['fresh'].update(indexedDB=None))
            if phase=='mutate':changes.extend([lambda v:v.update(strictCompleted=False),lambda v:v.update(abortedAfterRequestSuccess=False)])
            if phase=='read':changes.append(lambda v:v['before']['baseline'].update(indexedDB=None))
            for i,change in enumerate(changes):
                value=result(phase);change(value)
                with self.subTest(phase=phase,i=i),self.assertRaises(ValueError):F.validate_result(value,phase,'base','fresh')

    def test_mode_conflicts_refuse_before_manifest_or_native_inspection(self):
        for other in ('--manager-durability','--manager-websocket','--manager-webrtc','--controlled-dns','--owned-https','--physical-tcp','--allow-manager-preflight'):
            value=subprocess.run([sys.executable,'-B',str(ROOT/'manager-route-fixture.py'),'--app','/unused','--candidate-manifest','/unused',
                                  '--output','/unused','--manager-crash',other],capture_output=True,text=True)
            self.assertEqual(value.returncode,2);self.assertIn('separate fixture mode',value.stderr)
        for flag in ('manager_durability','manager_websocket','manager_webrtc','physical_tcp'):
            with self.assertRaises(ValueError): C.CORE.capture({},Path('/unused'),'direct-control',manager_crash=True,**{flag:True})
        with self.assertRaises(ValueError):C.CORE.capture({'crashFixture':{'mode':'wrong'}},Path('/unused'),'direct-control',manager_crash=True)

    def test_target_guard_rejects_stale_generation_lease_or_uncommitted_receipt(self):
        r,_,_=model();previous=r['crash-custody-mutate.json'];current=r['crash-intent.json']['custody'];events=r['fixture-ledger.json']['events']
        C.validate_target(previous,current,events)
        for key in ('browser','leaseSHA256','profileID','runtimeExecutableSHA256'):
            changed=copy.deepcopy(current);changed[key]={} if key=='browser' else 'changed'
            with self.assertRaises(ValueError):C.validate_target(previous,changed,events)
        for key in ('strictCompleted','abortedAfterRequestSuccess','abortedValueAbsent','baselineIntact','strictIDBRetained','wrote'):
            changed=copy.deepcopy(events);next(e for e in changed if e.get('kind')=='crash-result' and e.get('phase')=='mutate')[key]=False
            with self.assertRaises(ValueError):C.validate_target(previous,current,changed)
        with self.assertRaises(ValueError):C.validate_target(previous,current,[])


class CrashAnalysisTests(unittest.TestCase):
    def test_model_passes_only_declared_scope(self):
        value=A.qualify(*model());self.assertTrue(value['acknowledgedStrictIDBPreserved'])
        for key in ('powerLossQualified','relayCrashQualified','WebKitQualified','backupRestoreQualified','releaseGate'):self.assertFalse(value[key])

    def test_component_report_retains_unexplained_refusal_and_does_not_weaken_full_gate(self):
        receipts,release,state=model()
        receipts['fixture-ledger.json']['events'].insert(0,dict(kind='crash-http-refused',at=0.5))
        original=copy.deepcopy(receipts)
        components=A.measure_components(receipts,release,state)
        self.assertTrue(components['acknowledgedStrictIDBPreserved']);self.assertEqual(components['unclassifiedHTTPRefusals'],1)
        self.assertFalse(components['httpProtocolQualified']);self.assertFalse(components['fullScenarioQualified']);self.assertFalse(components['releaseGate'])
        self.assertNotIn('pass',components['result']);self.assertEqual(receipts,original)
        with self.assertRaisesRegex(ValueError,'crash-page-protocol'):A.qualify(receipts,release,state)
        next(e for e in receipts['fixture-ledger.json']['events'] if e.get('phase')=='read' and e['kind']=='crash-result')['strictIDBRetained']=False
        with self.assertRaises(ValueError):A.measure_components(receipts,release,state)

    def test_broken_native_evidence_refuses(self):
        def read(r):return next(e for e in r['fixture-ledger.json']['events'] if e.get('kind')=='crash-result' and e.get('phase')=='read')
        changes=[lambda r:r['crash-signal.json'].update(issued=False),lambda r:r['crash-signal.json'].update(processGroupSignaled=True),
                 lambda r:r['crash-signal.json']['target'].update(startMicroseconds=2),lambda r:r['crash-after.json'].update(mainGenerationAbsent=False),
                 lambda r:r['crash-after.json'].update(capturedDescendantsAbsent=False),lambda r:r['crash-after.json'].update(leaseRetired=False),
                 lambda r:r['crash-after.json'].update(dataOpenFiles=1),lambda r:r['crash-after.json'].update(at=26),
                 lambda r:r['crash-custody-read.json'].update(sessionGeneration='s1'),lambda r:r['crash-custody-read.json'].update(metadataIdentitySHA256='c'*64),
                 lambda r:r['crash-custody-read.json'].update(runtimeExecutableSHA256='c'*64),lambda r:r['crash-custody-read.json'].update(crashProbeSHA256='c'*64),
                 lambda r:r['fixture-ledger.json']['runtimeCleanup'].update(signaledMainProcesses=1),lambda r:r['crash-cleanup.json'].update(ownedProcessesRemaining=1),
                 lambda r:r['crash-cleanup.json']['observedExits'][1].update(status=0),lambda r:r['crash-intent.json'].update(descendants=[]),
                 lambda r:read(r).update(baselineIntact=False),lambda r:read(r).update(strictIDBRetained=False),lambda r:read(r).update(abortedValueAbsent=False),
                 lambda r:read(r).update(wrote=True),lambda r:read(r)['peer'].update(sessionGeneration='s1'),lambda r:read(r).update(at=19)]
        changes.extend([lambda r:r['crash-custody-read.json'].update(runtimeProcesses=[]),lambda r:read(r)['freshPresence'].update(indexedDB=False)])
        changes.extend([lambda r:r['crash-custody-read.json'].update(peerCollectorSHA256='c'*64),lambda r:r['crash-intent.json']['custody']['runtimeProcesses'].append(
            dict(identity=dict(pid=99,parentPID=12,uid=501,startSeconds=103,startMicroseconds=1,cdhash='b'*40),executable='/own/helper'))])
        changes.append(lambda r:r['fixture-ledger.json']['events'].insert(0,dict(kind='crash-http-refused',at=0.5)))
        changes.extend(lambda r,key=key:r['crash-ui.json'].update({key:False}) for key in A.UI_FLAGS)
        for i,change in enumerate(changes):
            receipts,release,state=copy.deepcopy(model());change(receipts)
            with self.subTest(i=i),self.assertRaises(ValueError):A.qualify(receipts,release,state)


class CrashSignalGuardTests(unittest.TestCase):
    def test_only_fully_rechecked_own_target_can_reach_mocked_signal_once(self):
        # No native APIs/signals: concrete private-file intent and final-guard
        # ordering are exercised while both kernel observation and kill are mocks.
        for fault in ('none','changed-generation','changed-lock','already-attempted'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory(prefix='neantik-crash-signal-model-') as temp:
                root=Path(temp);directory=root/'receipts';directory.mkdir(mode=0o700)
                lock=root/'manager-data/Profiles/own/.neantik.lock';lock.parent.mkdir(parents=True);lock.write_bytes(b'own-lock');lock.chmod(0o600)
                receipts,_,state=model();state.update(app='/unexecuted-own-app')
                current=copy.deepcopy(receipts['crash-custody-mutate.json']);current['leaseSHA256']=C.CORE.sha(b'own-lock')
                C.CORE.write_new(directory/'crash-custody-mutate.json',current)
                C.CORE.write_new(root/'observations.json',receipts['fixture-ledger.json']['events'])
                if fault=='changed-lock':lock.write_bytes(b'changed')
                if fault=='already-attempted':C.CORE.write_new(directory/'crash-intent.json',{})
                observed=copy.deepcopy(current['browser'])
                if fault=='changed-generation':observed['startMicroseconds']+=1
                with patch.object(C,'capture',return_value=current),patch.object(C.CORE,'kernel_process',return_value=observed),patch.object(C.os,'kill') as kill:
                    if fault=='none':
                        value=C.signal_own_main(state,root,directory);self.assertTrue(value['issued']);kill.assert_called_once_with(current['browser']['pid'],9)
                        with self.assertRaises(ValueError):C.signal_own_main(state,root,directory)
                        kill.assert_called_once()
                    else:
                        with self.assertRaises(ValueError):C.signal_own_main(state,root,directory)
                        kill.assert_not_called()

    def test_open_file_inventory_errors_missing_or_symlink_directories_never_mean_empty(self):
        with tempfile.TemporaryDirectory(prefix='neantik-crash-files-model-') as temp:
            root=Path(temp);data=root/'manager-data/BrowserData';data.mkdir(parents=True)
            for code,stdout,stderr,accept in [(1,'','',True),(1,'','inventory error',False),(0,'p123','',False),(0,'','',False),(2,'','',False)]:
                with self.subTest(code=code,stderr=stderr),patch.object(C.CORE.subprocess,'run',return_value=subprocess.CompletedProcess([],code,stdout,stderr)):
                    if accept:C.no_open_data_files(root,data)
                    else:
                        with self.assertRaises(ValueError):C.no_open_data_files(root,data)
            with self.assertRaises(FileNotFoundError):C.no_open_data_files(root,data/'missing')
            link=root/'link';link.symlink_to(data,target_is_directory=True)
            with self.assertRaises(ValueError):C.no_open_data_files(root,link)


class CrashWireTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='neantik-crash-wire-');self.f=F.ManagerCrashFixture(Path(self.temp.name))
        self.f.peer_inspector=lambda channel,direct:dict(protocolFixturePeer=True,direct=direct)
    def tearDown(self):self.assertTrue(self.f.close());self.temp.cleanup()
    def request(self,method,path,body=b''):
        with socket.create_connection(self.f.origin.server_address,timeout=3) as client:
            client.sendall(method+b' '+path.encode()+b' HTTP/1.1\r\nHost: own\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
            header=F.BASE.header(client);payload=bytearray()
            try:
                while chunk:=client.recv(16384):payload.extend(chunk)
            except ConnectionResetError:
                if not header.startswith(b'HTTP/1.1 400 '):raise
            return header,bytes(payload)
    def test_same_URL_ordered_three_phases_and_no_raw_markers_in_ledger(self):
        f=self.f
        for phase in F.PHASES:
            h,b=self.request(b'GET','/own-crash?nonce='+f.nonce);self.assertIn(b'200 OK',h);self.assertIn(('"phase": "'+phase+'"').encode(),b)
            h,_=self.request(b'POST','/own-crash-receipt?nonce='+f.nonce,json.dumps(result(phase,f.baseline,f.fresh)).encode());self.assertIn(b'200 OK',h)
        events=[e for e in f.ledger.events if e['kind']=='crash-result'];self.assertEqual([e['phase'] for e in events],list(F.PHASES))
        for marker in (f.baseline,f.fresh,f.nonce):self.assertNotIn(marker,json.dumps(f.ledger.events))
        self.assertFalse(events[-1]['wrote'])
    def test_wrong_nonce_early_receipt_duplicate_and_missing_custody_refuse(self):
        f=self.f
        self.assertIn(b'400',self.request(b'GET','/own-crash?nonce=wrong')[0])
        body=json.dumps(result('baseline',f.baseline,f.fresh)).encode()
        self.assertIn(b'400',self.request(b'POST','/own-crash-receipt?nonce='+f.nonce,body)[0])
        self.assertIn(b'200',self.request(b'GET','/own-crash?nonce='+f.nonce)[0])
        self.assertIn(b'400',self.request(b'GET','/own-crash?nonce='+f.nonce)[0])
        f.peer_inspector=None;self.assertIn(b'400',self.request(b'POST','/own-crash-receipt?nonce='+f.nonce,body)[0])
        self.assertFalse(any(e['kind']=='crash-result' for e in f.ledger.events))


if __name__=='__main__':unittest.main()
