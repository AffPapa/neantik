import copy,json,sys
from pathlib import Path
NAMES=['page','DedicatedWorker','SharedWorker','ServiceWorker','AudioWorklet','same-origin iframe','about:blank iframe','srcdoc iframe','cross-origin OOPIF']
def verify(d):
 issues=[];checks=0
 def require(ok,key):
  nonlocal checks
  checks+=1
  if not ok:issues.append(key)
 require(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-owned-process-cleanup')
 r=d['data']['results'];require([x.get('name') for x in r]==NAMES,'nine-exact-receipts')
 if len(r)!=9:return {'checks':checks,'issues':issues,'passed':False}
 values=[]
 require(d.get('documentEvidence',{}).get('loaded') is True,'owned-loaded-document')
 for i,x in enumerate(r):
  n=NAMES[i];require(x.get('created') is True and x.get('error') is None,n+':created')
  v=x.get('observation',{}).get('value',{});values.append(v);require(v.get('errors')==[],n+':capture-errors')
  require(isinstance(v.get('nonce'),str) and len(v['nonce'])>10,n+':nonce')
  expected='Window' if i in (0,5,6,7,8) else {'DedicatedWorker':'DedicatedWorkerGlobalScope','SharedWorker':'SharedWorkerGlobalScope','ServiceWorker':'ServiceWorkerGlobalScope','AudioWorklet':'AudioWorkletGlobalScope'}[n]
  require(v.get('realm')==expected,n+':own-realm')
  require(v.get('dom')==(expected=='Window'),n+':dom-exposure')
  require(all(isinstance(v.get(key),str) and bool(v[key]) and v.get('available',{}).get(key) is True for key in ('timezone','locale')),n+':intl-present')
  require(v.get('timezone')==values[0].get('timezone') and v.get('locale')==values[0].get('locale'),n+':intl')
  if i==4:
   require(all(v.get(key) is None and v.get('available',{}).get(key) is False for key in ('userAgent','platform','languages','hardwareConcurrency','deviceMemory','clientHints')),n+':lawful-nav-absence')
   require(v.get('dom') is False and v.get('offscreenCanvas') is False,n+':lawful-dom-canvas-absence')
   require(v.get('processingReceipt',{}).get('calls')==1 and v.get('audioWorkletSampleRate')==44100,n+':processing-receipt')
  else:
   require(v.get('secure') is True,n+':secure')
   navkeys=('userAgent','platform','languages','hardwareConcurrency','deviceMemory','clientHints')
   require(all(v.get('available',{}).get(key) is True for key in navkeys),n+':nav-availability')
   require(all(isinstance(v.get(key),str) and bool(v[key]) for key in ('userAgent','platform')),n+':nav-strings')
   require(isinstance(v.get('languages'),list) and bool(v['languages']) and all(isinstance(x,str) and bool(x) for x in v['languages']),n+':languages-present')
   require(type(v.get('hardwareConcurrency')) is int and v['hardwareConcurrency']>0 and type(v.get('deviceMemory')) in (int,float) and v['deviceMemory'] in (2,4,8,16,32),n+':nav-numeric-types')
   hints=v.get('clientHints',{});require(isinstance(hints,dict) and isinstance(hints.get('platform'),str) and bool(hints['platform']) and isinstance(hints.get('fullVersionList'),list) and bool(hints['fullVersionList']),n+':client-hints-present')
   for key in navkeys:require(v.get(key)==values[0].get(key),n+':'+key)
 require(len({v.get('nonce') for v in values})==9,'nine-independent-realms')
 require(r[3].get('observation',{}).get('registrationRemoved') is True,'service-registration-removed')
 oopif=r[8].get('observation',{});e=oopif.get('oopifEvidence',{}) or {}
 require(oopif.get('oopifProcessVerified') is True and e.get('confirmed') is True and e.get('targetType')=='iframe' and e.get('sessionAttached') is True and e.get('frameLinked') is True and e.get('defaultContextVerified') is True,'oopif-independent-session-frame-context')
 require(e.get('childValue',{}).get('nonce')==values[8].get('nonce'),'oopif-observation-in-own-session')
 require(values[6].get('url')=='about:blank','blank-own-url');require(values[7].get('url')=='about:srcdoc','srcdoc-own-url')
 return {'checks':checks,'issues':issues,'passed':not issues}
if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);r.update(label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],scope='creation/basic identity/Intl/processing/OOPIF linkage; complete per-realm Web APIs and individual CDP destruction receipts remain open')
 if '--negative-controls' in sys.argv:
  controls=[]
  for n,mutate in [('missing',lambda a:a['data']['results'].pop()),('duplicate',lambda a:a['data']['results'][1]['observation']['value'].__setitem__('nonce',a['data']['results'][0]['observation']['value']['nonce'])),('main-as-worker',lambda a:a['data']['results'][1]['observation'].__setitem__('value',copy.deepcopy(a['data']['results'][0]['observation']['value']))),('timeout',lambda a:a['data']['results'][2].__setitem__('created',False)),('oopif',lambda a:a['data']['results'][8]['observation']['oopifEvidence'].__setitem__('sessionAttached',False)),('processing',lambda a:a['data']['results'][4]['observation']['value'].__setitem__('processingReceipt',{})),('ua',lambda a:a['data']['results'][3]['observation']['value'].__setitem__('userAgent','contradiction'))]:
   a=copy.deepcopy(d);mutate(a);controls.append({'name':n,'rejected':not verify(a)['passed']})
  for name,keys in [('all-null-identity',('userAgent','platform','languages','hardwareConcurrency','deviceMemory','clientHints')),('all-null-intl',('timezone','locale'))]:
   a=copy.deepcopy(d)
   for realm in a['data']['results']:
    for key in keys:realm['observation']['value'][key]=None
   controls.append({'name':name,'rejected':not verify(a)['passed']})
  assert all(x['rejected'] for x in controls);r['negativeControls']=controls;r['negativeControlsQualified']=r['passed']
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
