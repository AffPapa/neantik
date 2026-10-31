import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('https_identity', ROOT/'scripts/runtime-platform/analyze-https-identity.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def identity():
    brands = [{'brand':'Chromium','version':'156'}]
    full = [{'brand':'Chromium','version':'156.0.8078.12'}]
    js = {'userAgent':'Owned QA UA','languages':['en-US','en'],'deviceMemory':8,
          'hints':{'brands':brands,'fullVersionList':full,'mobile':False,'platform':'macOS',
                   'architecture':'arm','bitness':'64','platformVersion':'15.0.0'}}
    headers = {'user-agent':'Owned QA UA','accept-language':'en-US,en;q=0.9',
               'sec-ch-ua':'"Chromium";v="156"','sec-ch-ua-full-version-list':'"Chromium";v="156.0.8078.12"',
               'sec-ch-ua-mobile':'?0','sec-ch-ua-platform':'"macOS"','sec-ch-ua-arch':'"arm"',
               'sec-ch-ua-bitness':'"64"','sec-ch-ua-platform-version':'"15.0.0"',
               'device-memory':'8','sec-ch-device-memory':'8'}
    return js, headers


def observation():
    runtime={'version':'156.0.8078.12','executableSHA256':'a'*64,'frameworkSHA256':'b'*64}
    release={'version':'0.8.17','build':129,'managerSHA256':'c'*64,'runtime':{'chromiumVersion':runtime['version'],'executableSHA256':runtime['executableSHA256'],'frameworkSHA256':runtime['frameworkSHA256']}}
    reference={'version':'155.0.8059.80','executableSHA256':'d'*64,'frameworkSHA256':'e'*64}
    report={'schemaVersion':1,'status':'observed','environment':{'headed':True,'architecture':'arm64'},'cleanup':{'fixtureClosed':True,'temporaryTLSKeyRemoved':True},
            'runtime':runtime,'reference':reference,'managerSHA256':release['managerSHA256'],'releaseVersion':release['version'],'releaseBuild':release['build'],'sources':{key:'f'*64 for key in MODULE.SOURCES},'runtimeHashesRechecked':True,'sessions':[],'admissionAttempts':[]}
    for mode in MODULE.MODES:
        selected=reference if mode=='chrome-reference' else runtime
        session={'mode':mode,'id':mode,'status':'observed','headed':True,'documentConfirmed':True,
                 'runtimeVersion':selected['version'],'runtimeSHA256':selected['executableSHA256'],'frameworkSHA256':selected['frameworkSHA256'],
                 'profileSeed':'21' if mode in ('configured','direct-negative') else None,
                 'cleanup':{'browserExited':True,'gracefulBrowserClose':True,'exitCode':0,'ownedProcessesRemaining':0},
                 'result':{'unregistered':True,'crossWarm':True,'secureContext':True,'rows':[]},'receipts':[],'connects':[]}
        for op in MODULE.OPERATIONS+('negative-language',):
            js,h=identity();rid=mode+op
            if op=='cross-not-delegated':
                for key in MODULE.HIGH:h[key]=None
            if op.startswith('worker'):
                for key in MODULE.HEADERS[2:]:h[key]=None
            if op=='negative-language':h['accept-language']='xx'
            custody={'sameProcessGroup':True,'runtimePathBound':True,'generationSHA256':'1'*64}
            role='b' if op in ('cross','cross-redirect','cross-not-delegated','worker-cross') else 'a'
            wire={'id':rid,'sessionID':mode,'path':'/identity','role':role,'nonce':rid,'operation':op,'headers':copy.deepcopy(h),'tls':True,'protocol':'TLSv1.3',
                  'throughProxy':mode!='direct-negative','connectID':rid if mode!='direct-negative' else None,'browserCustody':custody if mode!='direct-negative' else None,'directBrowserCustody':custody if mode=='direct-negative' else None}
            session['receipts'].append(wire)
            if mode!='direct-negative':session['connects'].append({'id':rid,'role':role,'sessionID':mode,'browserCustody':custody})
            session['result']['rows'].append({'operation':op,'nonce':rid,'js':js,'http':{'receiptID':rid,'nonce':rid,'operation':op,'headers':h}})
            if op in ('redirect','cross-redirect'):
                hop={**copy.deepcopy(wire),'id':rid+'hop','path':'/redirect' if op=='redirect' else '/cross-redirect','role':'a','connectID':mode+'resources' if mode!='direct-negative' else None}
                session['receipts'].append(hop)
        js,h=identity()
        for key in MODULE.HIGH:h[key]=None
        for resource,role in [('/','a'),('/warm','b'),('/policy-control','a'),('/worker.js','a'),('/owned-sw.js','a')]:
            wire={'id':mode+resource,'sessionID':mode,'path':resource,'role':role,'headers':h,'tls':True,'protocol':'TLSv1.3',
                  'throughProxy':mode!='direct-negative','connectID':mode+'resource'+role if mode!='direct-negative' else None,'browserCustody':custody if mode!='direct-negative' else None,'directBrowserCustody':custody if mode=='direct-negative' else None}
            session['receipts'].append(wire)
        if mode!='direct-negative':
            session['connects'].extend([{'id':mode+'resource'+role,'role':role,'sessionID':mode,'browserCustody':custody} for role in ('a','b')])
            for wire in session['receipts']:
                if wire['id'].endswith('hop'):wire['connectID']=mode+'resourcea'
        report['sessions'].append(session);report['admissionAttempts'].append({'mode':mode,'exitCode':0,'readiness':{'eligibleForAttempt':True}})
    return report,release,reference


class HTTPSIdentityTests(unittest.TestCase):
    def test_fixture_actual_tls_connect_direct_and_denial(self):
        result=subprocess.run(['node',str(ROOT/'scripts/runtime-platform/fixtures/test-https-identity.mjs')],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(json.loads(result.stdout)['actualTLS'])

    def test_full_positive_contract_and_negative_controls(self):
        report,release,reference=observation()
        self.assertTrue(MODULE.verify(report,release,reference)['passed'])
        changes=[lambda d:d['sessions'].pop(),lambda d:d['sessions'][2]['result']['rows'].pop(),
                 lambda d:d['sessions'][2]['result'].__setitem__('unregistered',False),
                 lambda d:d['sessions'][2]['result']['rows'][0].__setitem__('nonce','wrong'),
                 lambda d:d['sessions'][2]['receipts'][0].__setitem__('tls',False),
                 lambda d:d['sessions'][2]['receipts'][0].__setitem__('browserCustody',None),
                 lambda d:d['sessions'][2]['receipts'].append(copy.deepcopy(d['sessions'][2]['receipts'][0])),
                 lambda d:d['sessions'][2]['result']['rows'][0]['http']['headers'].pop('sec-ch-ua'),
                 lambda d:d['sessions'][2]['cleanup'].__setitem__('ownedProcessesRemaining',1)]
        for mutate in changes:
            changed=copy.deepcopy(report);mutate(changed);self.assertFalse(MODULE.verify(changed,release,reference)['passed'])

    def test_value_and_absence_are_distinct(self):
        js,h=identity();self.assertEqual(MODULE.identity_issues(js,h),[])
        h['accept-language']='xx';self.assertEqual(MODULE.identity_issues(js,h),['languages'])
        h['accept-language']='en-US,en;q=0.9';h['sec-ch-ua-bitness']='"32"'
        self.assertIn('value:sec-ch-ua-bitness',MODULE.identity_issues(js,h))
        h['sec-ch-ua-bitness']=None
        self.assertIn('availability:sec-ch-ua-bitness',MODULE.identity_issues(js,h,{'sec-ch-ua-bitness':True}))
        h.pop('sec-ch-ua-bitness');self.assertEqual(MODULE.identity_issues(js,h),['missing-identity'])

    def test_cross_origin_hop_custody_and_missing_proof_cannot_pass(self):
        report,release,reference=observation()
        def wrong_cross(d):
            s=d['sessions'][2];w=next(x for x in s['receipts'] if x.get('operation')=='cross' and x['path']=='/identity')
            w['role']='a';next(x for x in s['connects'] if x['id']==w['connectID'])['role']='a'
        def lost_warm(d):
            w=next(x for x in d['sessions'][2]['receipts'] if x['path']=='/warm')
            w.update(throughProxy=False,connectID=None,browserCustody=None)
        def lost_direct(d):
            d['sessions'][3]['receipts'][0].update(throughProxy=True,directBrowserCustody=None)
        for mutate in (wrong_cross,lost_warm,lost_direct,
                       lambda d:d.__setitem__('runtimeHashesRechecked',False),
                       lambda d:d.__setitem__('sources',{'source':'f'*64})):
            changed=copy.deepcopy(report);mutate(changed)
            self.assertFalse(MODULE.verify(changed,release,reference)['passed'])


if __name__=='__main__':unittest.main()
