"""Offline sensitivity controls; constructed receipts never imply native PASS."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / 'runtime-network/analyze-manager-dns.py'
SPEC = importlib.util.spec_from_file_location('manager_dns_analysis_test', PATH)
MOD = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)


def evidence():
    def proc(pid, parent=100):
        return dict(pid=pid, parentPID=parent, uid=501, startSeconds=1000, startMicroseconds=10, cdhash='a'*40)
    baseline = dict(phase='before-launch', at=1., manager=proc(100, 1), profileID='a'*32,
        revision=3, metadataIdentitySHA256='d'*64, lastLaunchedAt=None, updatedAt='before',
        managerSHA256='c'*64, candidateManifestSHA256='e'*64, configurationSHA256='f'*64,
        version='0.8.15', build='127', directBaseline=dict(profileID='b'*32, revision=0, metadataIdentitySHA256='b'*64))
    for key, name in MOD.HASHES.items(): baseline[key]=MOD.COLLECT.sha(PATH.with_name(name).read_bytes())
    relay = dict(profileID='a'*32, sessionGeneration='f'*32, ownerPID=102,
        ownerStartSeconds=1000, ownerStartMicroseconds=10, ownerUID=501, loopbackPort=3000,
        runtimeExecutableSHA256='1'*64, runtimeFrameworkSHA256='2'*64, configurationSHA256='f'*64)
    samples=[baseline]
    for phase, at in [('proxy-success',3.),('dns-refused',6.),('direct-control',12.),('proxy-recovered',15.)]:
        sample=copy.deepcopy(baseline); sample.update(phase=phase,at=at,revision=4,lastLaunchedAt='launched',updatedAt='launched',
            browser=proc(101),relayOwner=proc(102),relay=relay,sessionGeneration='f'*32,leaseSHA256='9'*64)
        if phase=='direct-control':
            sample.update(profileID='b'*32,revision=1,metadataIdentitySHA256='b'*64,browser=proc(103),sessionGeneration='c'*32)
            for key in ('relayOwner','relay','configurationSHA256'):sample.pop(key)
        samples.append(sample)
    def control(at, epoch):return dict(kind='dns-control',at=at,faultEpoch=epoch,faultEnabled=epoch==1,controlConsistent=True)
    def event(kind, at, phase, rid, epoch, **kw):
        return dict(kind=kind,at=at,phase=phase,requestID=rid*32,requestEpoch=epoch,faultEpoch=epoch,
                    faultEnabled=epoch==1,controlConsistent=True,**kw)
    def wire(at,phase,code):return dict(kind='dns-wire',at=at,phase=phase,transport='udp',queryType=1,rcode=code,responseSent=True)
    events=[control(.5,0),event('dns-request-begin',1.5,'proxy-success','1',0),
        event('dns-resolution-accepted',2.,'proxy-success','1',0,rcode=0),wire(2.1,'proxy-success',0),
        event('origin',2.5,'proxy-success','1',0,throughOwnedUpstream=True),control(4.,1),
        event('dns-request-begin',4.5,'dns-refused','2',1),wire(4.6,'dns-refused',2),
        event('dns-resolution-rejected',5.,'dns-refused','2',1,rcode=2),
        event('origin',11.,'direct-control','3',1,throughOwnedUpstream=False),control(13.,2),
        event('dns-request-begin',13.1,'proxy-recovered','4',2),wire(13.2,'proxy-recovered',0),
        event('dns-resolution-accepted',13.3,'proxy-recovered','4',2,rcode=0),
        event('origin',14.,'proxy-recovered','4',2,throughOwnedUpstream=True)]
    with_peers=[]
    for event_value in events:
        if event_value['kind']=='origin':
            event_value['arrivalID']='a'+event_value['requestID'][1:]
            with_peers.append(dict(kind='dns-origin-arrival',at=event_value['at']-.2,phase=event_value['phase'],
                throughOwnedUpstream=event_value['throughOwnedUpstream'],arrivalID=event_value['arrivalID'],controlConsistent=True))
        if event_value['kind']=='origin' and not event_value['throughOwnedUpstream']:
            s=samples[3]
            with_peers.append(dict(kind='dns-direct-peer',at=event_value['at']-.1,requestID=event_value['requestID'],
                manager=s['manager'],browser=s['browser'],profileID=s['profileID'],sessionGeneration=s['sessionGeneration'],
                configurationSHA256=None,socketTupleSHA256='8'*64,peerChain=[s['browser']]))
        with_peers.append(event_value)
        if event_value['kind']=='dns-request-begin':
            s=samples[1]
            with_peers.append(dict(kind='dns-request-peer',at=event_value['at']+.01,requestID=event_value['requestID'],
                manager=s['manager'],browser=s['browser'],profileID=s['profileID'],sessionGeneration=s['sessionGeneration'],
                configurationSHA256=s['configurationSHA256'],socketTupleSHA256='7'*64,peerChain=[s['relayOwner']]))
    events=with_peers
    result={f'dns-custody-{s["phase"]}.json':s for s in samples}
    result['fixture-ledger.json']=dict(schemaVersion=1,events=events,serverThreadsDrained=True,managerExitCode=0,
        runtimeCleanup=dict(ownedRuntimeProcessesRemaining=0))
    result['dns-custody-cleanup.json']=dict(at=17.,collectorSHA256=baseline['collectorSHA256'],ownedProcessesRemaining=0,ordinaryInstanceTouched=False)
    return result


def preflight_evidence():
    receipts = evidence()
    baseline = receipts['dns-custody-before-launch.json']
    profile = dict(id=baseline['profileID'], name='QA route proxy', revision=5,
        updatedAt='2026-10-15T14:30:02Z', lastLaunchedAt='2026-10-15T14:30:02Z',
        identity=dict(seed='unchanged', tuple='unchanged', catalogVersion=1),
        proxy=dict(kind='http', host='127.0.0.1', port=62183, username='owned-fixture-user'),
        startURL='http://fixture.test/')
    baseline['updatedAt'] = '2026-10-15T14:29:42Z'
    baseline['metadataIdentitySHA256'] = MOD.COLLECT.metadata_identity(profile)
    original = copy.deepcopy(profile); original['revision'] = 3
    baseline['configurationSHA256'] = MOD.COLLECT.configuration_digest(original)
    original['revision'] = 4
    prepared = MOD.COLLECT.configuration_digest(original)
    profile['identity'].update(timezoneIdentifier='Asia/Bangkok', localeIdentifier='th',
        proxyContextEvidence=dict(source='ipwho.is+freeipapi.com', observedAt='2026-10-15T14:30:01Z'))
    for phase in ('proxy-success', 'dns-refused', 'proxy-recovered'):
        sample = receipts['dns-custody-' + phase + '.json']
        sample.update(revision=5, metadataIdentitySHA256=MOD.COLLECT.metadata_identity(profile),
                      updatedAt=profile['updatedAt'], lastLaunchedAt=profile['lastLaunchedAt'], configurationSHA256=prepared)
        sample['relay']['configurationSHA256'] = prepared
    for event in receipts['fixture-ledger.json']['events']:
        if event['kind'] == 'dns-request-peer': event['configurationSHA256'] = prepared
    witness = dict(schemaVersion=1, mode='absent-context-preflight-then-launch', sourceMetadataSHA256='a'*64,
                   receiptCanonicalSHA256=MOD.TRANSITION.receipt_hashes(receipts), selectedProfile=profile)
    return receipts, witness


class ManagerDNSAnalysisTests(unittest.TestCase):
    def test_failed_navigation_may_retry_only_during_same_armed_fault(self):
        for at, valid in [(7., True), (12.4, True), (13.05, False)]:
            receipts=evidence(); events=receipts['fixture-ledger.json']['events']
            originals=[e for e in events if e.get('requestID') == '2'*32]
            for original in originals:
                retry=copy.deepcopy(original);retry['requestID']='5'*32;retry['at'] += at - 4.5
                events.append(retry)
            events.sort(key=lambda e:e['at'])
            if valid:self.assertEqual(MOD.qualify(receipts)['result'],'scoped-manager-dns-observations-pass')
            else:
                with self.assertRaisesRegex(ValueError,'refusal-outside-window'):MOD.qualify(receipts)
        receipts=evidence()
        for event in receipts['fixture-ledger.json']['events']:
            if event.get('requestID') == '2'*32:event['at'] += 2
        receipts['fixture-ledger.json']['events'].sort(key=lambda e:e['at'])
        with self.assertRaisesRegex(ValueError,'refusal-outside-window'):MOD.qualify(receipts)

    def test_preflight_requires_exact_offline_proof_and_preserves_legacy_control(self):
        receipts, witness = preflight_evidence()
        with self.assertRaises(ValueError): MOD.qualify(receipts)
        self.assertEqual(MOD.qualify(receipts, witness)['result'], 'scoped-manager-dns-observations-pass')
        self.assertEqual(MOD.qualify(evidence())['result'], 'scoped-manager-dns-observations-pass')

    def test_witness_cannot_hide_any_other_profile_change(self):
        edits = [('seed','other'), ('tuple','other'), ('catalogVersion',2), ('issuedAt','extra'),
                 ('unknownFutureIdentityField','extra')]
        for field, value in edits:
            receipts, witness = preflight_evidence(); witness['selectedProfile']['identity'][field] = value
            # Even a matched POST hash cannot hide a changed baseline field.
            for phase in ('proxy-success','dns-refused','proxy-recovered'):
                receipts['dns-custody-'+phase+'.json']['metadataIdentitySHA256'] = MOD.COLLECT.metadata_identity(witness['selectedProfile'])
            witness['receiptCanonicalSHA256'] = MOD.TRANSITION.receipt_hashes(receipts)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError,'baseline-metadata'): MOD.qualify(receipts,witness)
        for field, value in [('startURL','other'), ('name','QA route proxy changed'), ('futureField','extra'),
                             ('proxy',dict(kind='http',host='other',port=80,username='other'))]:
            receipts,witness = preflight_evidence(); witness['selectedProfile'][field]=value
            for phase in ('proxy-success','dns-refused','proxy-recovered'):
                receipts['dns-custody-'+phase+'.json']['metadataIdentitySHA256'] = MOD.COLLECT.metadata_identity(witness['selectedProfile'])
            witness['receiptCanonicalSHA256'] = MOD.TRANSITION.receipt_hashes(receipts)
            with self.subTest(field=field),self.assertRaises(ValueError): MOD.qualify(receipts,witness)

    def test_witness_rejects_wrong_context_revision_timestamp_and_shape(self):
        for key,value in [('timezoneIdentifier','Not/AZone'),('localeIdentifier','bad locale'),
            ('proxyContextEvidence',dict(source='untrusted',observedAt='2026-10-15T14:30:01Z')),
            ('proxyContextEvidence',dict(source='ipapi.co',observedAt='2026-10-15T14:29:41Z')),
            ('proxyContextEvidence',dict(source='ipapi.co',observedAt='2026-10-15T14:30:03Z')),
            ('proxyContextEvidence',dict(source='ipapi.co',observedAt='not a date'))]:
            receipts,witness = preflight_evidence();witness['selectedProfile']['identity'][key]=value
            for phase in ('proxy-success','dns-refused','proxy-recovered'):
                receipts['dns-custody-'+phase+'.json']['metadataIdentitySHA256'] = MOD.COLLECT.metadata_identity(witness['selectedProfile'])
            witness['receiptCanonicalSHA256'] = MOD.TRANSITION.receipt_hashes(receipts)
            with self.subTest(context=key,value=value),self.assertRaises(ValueError): MOD.qualify(receipts,witness)
        for key in MOD.TRANSITION.CONTEXT:
            receipts,witness=preflight_evidence();del witness['selectedProfile']['identity'][key]
            with self.subTest(missing=key),self.assertRaises(ValueError):MOD.qualify(receipts,witness)
        for revision in (4,6,True):
            receipts,witness=preflight_evidence();witness['selectedProfile']['revision']=revision
            with self.subTest(revision=revision),self.assertRaises(ValueError):MOD.qualify(receipts,witness)
        for key,value in [('schemaVersion',True),('mode','ignore-identity'),('sourceMetadataSHA256',None),('extra',True)]:
            receipts,witness=preflight_evidence();witness[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):MOD.qualify(receipts,witness)

    def test_witness_cannot_rebind_stale_phase_or_configuration(self):
        for field,value in [('metadataIdentitySHA256','0'*64),('revision',6),('updatedAt','changed'),
            ('lastLaunchedAt','changed'),('configurationSHA256','0'*64),('sessionGeneration','0'*32),('leaseSHA256','0'*64)]:
            receipts,witness=preflight_evidence();receipts['dns-custody-dns-refused.json'][field]=value
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'receipt-binding'):MOD.qualify(receipts,witness)
            witness['receiptCanonicalSHA256']=MOD.TRANSITION.receipt_hashes(receipts)
            with self.subTest(rebound=field),self.assertRaises(ValueError):MOD.qualify(receipts,witness)
        receipts,witness=preflight_evidence();receipts['dns-custody-before-launch.json']['configurationSHA256']='0'*64
        witness['receiptCanonicalSHA256']=MOD.TRANSITION.receipt_hashes(receipts)
        with self.assertRaisesRegex(ValueError,'baseline-config'):MOD.qualify(receipts,witness)

    def test_file_analysis_binds_witness_and_unchanged_raw_receipts(self):
        receipts,witness=preflight_evidence()
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            for name,value in receipts.items():
                path=root/name;path.write_text(json.dumps(value));path.chmod(0o600)
            witness_path=root/'transition.json';witness_path.write_text(json.dumps(witness));witness_path.chmod(0o600)
            result=MOD.analyze(root,witness_path)
            self.assertEqual(result['result'],'scoped-manager-dns-observations-pass')
            self.assertEqual(set(result['inputSHA256']),set(MOD.INPUTS))
            self.assertIn('transitionWitnessSHA256',result)
            for flag in ('releaseGate','allNetworkGatesComplete','globalDNSQualified'):self.assertFalse(result[flag])

    def test_complete_offline_control_passes_with_explicit_scope(self):
        result=MOD.qualify(evidence())
        self.assertEqual(result['result'],'scoped-manager-dns-observations-pass')
        for field in ('globalDNSQualified','allNetworkGatesComplete','releaseGate'):self.assertIs(result[field],False)
        self.assertIn('no OS resolver',result['managerDNSScope'])

    def test_each_missing_custody_or_event_fails(self):
        for name in MOD.INPUTS:
            value=evidence();value.pop(name)
            with self.subTest(name=name),self.assertRaises(ValueError):MOD.qualify(value)
        for kind in ('dns-control','dns-request-begin','dns-request-peer','dns-direct-peer','dns-resolution-accepted','dns-resolution-rejected','dns-wire','origin'):
            value=evidence();value['fixture-ledger.json']['events']=[e for e in value['fixture-ledger.json']['events'] if e['kind']!=kind]
            with self.subTest(kind=kind),self.assertRaises(ValueError):MOD.qualify(value)

    def test_changed_session_config_runtime_revision_and_live_code_are_rejected(self):
        mutations=[('revision',5),('revision',True),('profileID','wrong'),('configurationSHA256','0'*64),
            ('sessionGeneration','0'*32),('metadataIdentitySHA256','0'*64),('lastLaunchedAt','changed'),
            ('updatedAt','changed'),('leaseSHA256','0'*64),('managerSHA256','0'*64),('candidateManifestSHA256','0'*64)]
        for key,value in mutations:
            receipts=evidence();receipts['dns-custody-dns-refused.json'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):MOD.qualify(receipts)
        for field in ('browser','relayOwner','manager'):
            for key,value in [('pid',999),('startMicroseconds',20),('cdhash','0'*40)]:
                receipts=evidence();receipts['dns-custody-proxy-recovered.json'][field][key]=value
                with self.subTest(field=field,key=key),self.assertRaises(ValueError):MOD.qualify(receipts)
        for key in ('configurationSHA256','runtimeExecutableSHA256','runtimeFrameworkSHA256','ownerPID','ownerStartSeconds','ownerUID'):
            receipts=evidence();receipts['dns-custody-proxy-recovered.json']['relay']=copy.deepcopy(receipts['dns-custody-proxy-recovered.json']['relay'])
            receipts['dns-custody-proxy-recovered.json']['relay'][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):MOD.qualify(receipts)

    def test_bypass_wrong_fault_stale_resolution_and_duplicates_fail(self):
        edits=[('dns-resolution-accepted','requestID','0'*32),('dns-resolution-rejected','rcode',True),
            ('dns-resolution-rejected','faultEnabled',False),('dns-resolution-rejected','requestEpoch',0),
            ('dns-resolution-rejected','controlConsistent',False),('origin','throughOwnedUpstream',False)]
        for kind,field,value in edits:
            receipts=evidence();next(e for e in receipts['fixture-ledger.json']['events'] if e['kind']==kind)[field]=value
            with self.subTest(kind=kind,field=field),self.assertRaises(ValueError):MOD.qualify(receipts)
        for kind in ('dns-control','dns-request-begin','dns-resolution-accepted','origin'):
            receipts=evidence();events=receipts['fixture-ledger.json']['events'];index=next(i for i,e in enumerate(events) if e['kind']==kind)
            events.insert(index,copy.deepcopy(events[index]))
            with self.subTest(duplicate=kind),self.assertRaises(ValueError):MOD.qualify(receipts)
        receipts=evidence();events=receipts['fixture-ledger.json']['events']
        index=next(i for i,e in enumerate(events) if e['at']>7.)
        events.insert(index,dict(kind='origin',at=7.,phase='dns-refused',throughOwnedUpstream=False,requestID='a'*32,
                            requestEpoch=1,faultEpoch=1,faultEnabled=True,controlConsistent=True))
        with self.assertRaises(ValueError):MOD.qualify(receipts)

    def test_different_local_client_cannot_manufacture_browser_dns_pass(self):
        for kind in ('dns-request-peer','dns-direct-peer'):
            receipts=evidence();peer=next(e for e in receipts['fixture-ledger.json']['events'] if e['kind']==kind)
            peer['peerChain']=copy.deepcopy(peer['peerChain']);peer['peerChain'][0]['pid']=999
            with self.subTest(kind=kind),self.assertRaises(ValueError):MOD.qualify(receipts)
        for field,value in [('configurationSHA256','0'*64),('sessionGeneration','0'*32),('socketTupleSHA256',None)]:
            receipts=evidence();peer=next(e for e in receipts['fixture-ledger.json']['events'] if e['kind']=='dns-request-peer')
            peer[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):MOD.qualify(receipts)

    def test_rejected_direct_bypass_is_still_a_failed_origin_arrival(self):
        receipts=evidence();events=receipts['fixture-ledger.json']['events'];index=next(i for i,e in enumerate(events) if e['at']>7.)
        events.insert(index,dict(kind='dns-origin-arrival',at=7.,phase='dns-refused',throughOwnedUpstream=False,
                                arrivalID='f'*32,controlConsistent=True))
        with self.assertRaisesRegex(ValueError,'unintended-direct-origin-arrival'):MOD.qualify(receipts)
        receipts=evidence();events=receipts['fixture-ledger.json']['events']
        events.insert(index,dict(kind='dns-origin-arrival',at=7.,phase='proxy-success',throughOwnedUpstream=True,
                                arrivalID='f'*32,controlConsistent=True))
        with self.assertRaisesRegex(ValueError,'rejected-or-unaccounted-origin-arrival'):MOD.qualify(receipts)

    def test_direct_fault_recovery_and_cleanup_must_be_real(self):
        for phase,field,value in [('direct-control','faultEnabled',False),('direct-control','faultEpoch',2),
                                  ('proxy-recovered','faultEnabled',True),('proxy-recovered','faultEpoch',1)]:
            receipts=evidence();next(e for e in receipts['fixture-ledger.json']['events'] if e['kind']=='origin' and e['phase']==phase)[field]=value
            with self.subTest(phase=phase,field=field),self.assertRaises(ValueError):MOD.qualify(receipts)
        receipts=evidence()
        for e in receipts['fixture-ledger.json']['events']:
            if e['kind']=='dns-origin-arrival' and e['phase']=='direct-control':e['at']=8.8
            if e['kind']=='dns-direct-peer':e['at']=8.9
            if e['kind']=='origin' and e['phase']=='direct-control':e['at']=9.
        with self.assertRaisesRegex(ValueError,'failure-window-too-short'):MOD.qualify(receipts)
        for value in [1,False,None]:
            receipts=evidence();receipts['dns-custody-cleanup.json']['ownedProcessesRemaining']=value
            with self.subTest(cleanup=value),self.assertRaises(ValueError):MOD.qualify(receipts)

    def test_file_analysis_pins_sources_and_rejects_stale_harness_without_browser_retry(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            def store(receipts):
                for name,value in receipts.items():
                    path=root/name;path.write_text(json.dumps(value));path.chmod(0o600)
            store(evidence());self.assertEqual(MOD.analyze(root)['result'],'scoped-manager-dns-observations-pass')
            value=evidence()
            for key in value:
                if key.startswith('dns-custody-') and key!='dns-custody-cleanup.json':value[key]['dnsWireFixtureSHA256']='0'*64
            store(value)
            with self.assertRaisesRegex(ValueError,'harness-input-changed'):MOD.analyze(root)


if __name__=='__main__':unittest.main()
