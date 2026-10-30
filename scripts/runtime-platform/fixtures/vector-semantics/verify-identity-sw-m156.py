"""Independently nonce-bound page request through actual Service Worker.
Baseline and controlled receipts must both exist in the server ledger.
"""
import copy,hashlib,json,re,sys
from pathlib import Path
import os
def candidate_binding():
 return json.loads(Path(os.environ["NEANTIK_PLATFORM_BINDING"]).read_text())

def sf_string(v):
 try:return json.loads(v) if isinstance(v,str) else None
 except (ValueError,TypeError):return None

def brands(v):
 if not isinstance(v,str):return None
 result=[];end=0
 for m in re.finditer(r'("(?:[^"\\]|\\.)*");v=("(?:[^"\\]|\\.)*")',v):
  if v[end:m.start()].strip() not in ('',','):return None
  result.append({'brand':sf_string(m[1]),'version':sf_string(m[2])});end=m.end()
 if v[end:].strip() or not result:return None
 return result

def verify(d):
 issues=[];checks=0
 def need(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 need(d.get('runtimeVersion')==candidate_binding()['runtimeVersion'] and d.get('executableSHA256')==candidate_binding()['runtimeExecutableSHA256'] and d.get('runtimeFrameworkSHA256')==candidate_binding()['runtimeFrameworkSHA256'],'exact-runtime')
 need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup')
 need(d.get('documentEvidence',{}).get('loaded') is True,'owned-loaded-document')
 need(d.get('browserClosure',{}).get('gracefulParentExit') is True,'graceful-exit')
 files={x['path']:x['sha256'] for x in d.get('fixtureProvenance',{}).get('files',[])}
 need(files.get('vector-semantics/identity-sw-probe.js')==d.get('probeSHA256'),'probe-binding')
 need(files.get('vector-semantics/run-headed-m156-sw-identity.mjs')==d.get('runnerSHA256') and bool(files.get('vector-semantics/identity-sw-worker.js')),'runner-worker-binding')
 need(d.get('fixtureSourceArchive',{}).get('manifestSHA256')==d.get('fixtureProvenance',{}).get('manifestSHA256'),'source-archive')
 a=d.get('data',{});need(a.get('kind')=='page-controlled-sw-http-identity','actual-operation')
 if a.get('kind')!='page-controlled-sw-http-identity':return {'checks':checks,'issues':issues,'passed':False}
 need(a.get('controller',{}).get('state')=='activated' and a['controller'].get('scriptURL')==a.get('expectedWorker'),'actual-controller')
 need(a.get('unregistered') is True and a.get('remainingRegistrations')==0,'registration-cleanup')
 js=a['js'];hints=js['hints'];ledger=d.get('ownIdentityReceipts',[])
 need(a['baseline']['requestNonce']!=a['controlled']['requestNonce'],'different-nonces')
 for step,via in [('baseline','baseline'),('controlled','sw-controlled')]:
  x=a[step];receipt=x.get('http',{});matches=[r for r in ledger if r.get('requestNonce')==x.get('requestNonce') and r.get('via')==via]
  need(len(matches)==1,step+':independent-server-receipt')
  need(len(matches)==1 and matches[0]==receipt,step+':echo-ledger-binding')
  need(receipt.get('requestNonce')==x.get('requestNonce') and receipt.get('via')==via,step+':request-binding')
  h=receipt.get('headers',{})
  need(bool(js.get('userAgent')) and h.get('user-agent')==js['userAgent'],step+':UA')
  langs=[v.split(';')[0].strip() for v in (h.get('accept-language') or '').split(',')]
  need(bool(js.get('languages')) and langs[:len(js['languages'])]==js['languages'],step+':languages')
  need(js.get('deviceMemory') in (2,4,8,16,32),step+':coarse-memory')
  for key in ('device-memory','sec-ch-device-memory'):need(h.get(key)==str(js['deviceMemory']),step+':'+key)
  for key,field in [('sec-ch-ua-platform','platform'),('sec-ch-ua-arch','architecture'),('sec-ch-ua-bitness','bitness'),('sec-ch-ua-platform-version','platformVersion')]:need(bool(hints.get(field)) and sf_string(h.get(key))==hints[field],step+':'+field)
  need(type(hints.get('mobile')) is bool and h.get('sec-ch-ua-mobile')==('?1' if hints['mobile'] else '?0'),step+':mobile')
  need(bool(hints.get('brands')) and brands(h.get('sec-ch-ua'))==hints['brands'],step+':brands')
  need(bool(hints.get('fullVersionList')) and brands(h.get('sec-ch-ua-full-version-list'))==hints['fullVersionList'],step+':full-version')
 intercepted=a.get('interception',{});need(intercepted.get('sourceScriptURL')==a['expectedWorker'] and intercepted.get('data',{}).get('scriptURL')==a['expectedWorker'],'interception-worker-source')
 need(intercepted.get('data',{}).get('ownInterceptedNonce')==a['controlled']['requestNonce'],'interception-nonce')
 need(intercepted.get('data',{}).get('requestURL','').endswith('/identity?via=sw-controlled&requestNonce='+a['controlled']['requestNonce']),'interception-request')
 need(a['baseline']['http']['headers']==a['controlled']['http']['headers'],'pass-through-preserves-header-identity')
 return {'checks':checks,'issues':issues,'passed':not issues}

if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d)
 def contradict(a,key,value):
  a['data']['controlled']['http']['headers'][key]=value
  for row in a['ownIdentityReceipts']:
   if row.get('via')=='sw-controlled':row['headers'][key]=value
 controls=[('platform-contradiction',lambda a:contradict(a,'sec-ch-ua-platform','"Windows"')),('memory-contradiction',lambda a:contradict(a,'device-memory','4' if a['data']['js']['deviceMemory']!=4 else '8')),('version-contradiction',lambda a:contradict(a,'sec-ch-ua-full-version-list','"Chromium";v="1.0"')),('missing-controller',lambda a:a['data'].__setitem__('controller',{})),('foreign-interception',lambda a:a['data']['interception']['data'].__setitem__('ownInterceptedNonce','foreign')),('synthetic-response-no-server',lambda a:a.__setitem__('ownIdentityReceipts',[x for x in a['ownIdentityReceipts'] if x.get('via')!='sw-controlled'])),('duplicate-server',lambda a:a['ownIdentityReceipts'].append(copy.deepcopy(a['data']['controlled']['http']))),('timeout',lambda a:a.__setitem__('data',{'error':'timeout'})),('wrong-runtime',lambda a:a.__setitem__('executableSHA256','0'*64)),('cleanup',lambda a:a.__setitem__('cleanupVerified',False))]
 r['negativeControls']=[]
 for name,mutate in controls:
  a=copy.deepcopy(d);mutate(a);r['negativeControls'].append({'name':name,'rejected':not verify(a)['passed']})
 assert all(x['rejected'] for x in r['negativeControls'])
 r.update(runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],observationSHA256=hashlib.sha256(p.read_bytes()).hexdigest(),scope='Owned HTTP loopback page fetch pass-through actual ServiceWorker; TLS and final manager remain separate.')
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
