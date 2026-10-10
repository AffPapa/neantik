import copy,json,sys
from pathlib import Path

def verify(d):
 checks=0;issues=[]
 def need(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup');x=d['data'];need(x.get('errors')==[],'capture-errors')
 need([(c['failure'],c['listenerMode']) for c in x['cases']]==[('constructor','replace'),('process','replace'),('missing-process','replace'),('process','null'),('process','remove')],'error-mode-coverage')
 for c in x['cases']:
  p=c['failure']+':'+c['listenerMode']+':';mode=c['listenerMode'];need(c['renderCompleted'] and c['state']=='closed' and c['outputLength']==1024 and c['silence'],p+'render-silence')
  need(c['getterMatches'] and c['oldCalls']==0,p+'attribute-replacement-getter')
  need(c['attributeCallsBeforeSynthetic']==(0 if mode=='null' else 1),p+'attribute-count');need(c['listenerCalls']==(0 if mode=='remove' else 1),p+'independent-listener-count')
  need(c['legacyCallsBeforeSynthetic']==0,p+'no-legacy-alias');need(c['sameNativeEvent'],p+'one-native-event')
  native=c['native'];need(isinstance(native,dict) and native.get('type')=='processorerror' and native.get('errorEvent') is True and native.get('trusted') is True and native.get('bubbles') is False and native.get('cancelable') is False and native.get('messagePresent') is True,p+'native-event-contract')
  need(c['syntheticErrorInvokedAttribute'] is False,p+'synthetic-error-negative');need(c['portClosed'] and c['disconnected'],p+'own-release')
 return {'checks':checks,'issues':issues,'passed':not issues}

if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);r['negativeControlsQualified']=r['passed'];controls=[]
 for name,mutate in [('legacy-event-name',lambda a:a['data']['cases'][0]['native'].__setitem__('type','error')),('listener-missing',lambda a:a['data']['cases'][0].__setitem__('listenerCalls',0)),('attribute-removed-wrongly',lambda a:a['data']['cases'][3].__setitem__('attributeCallsBeforeSynthetic',1)),('untrusted-event',lambda a:a['data']['cases'][0]['native'].__setitem__('trusted',False)),('cancelable-error',lambda a:a['data']['cases'][0]['native'].__setitem__('cancelable',True)),('duplicate-event-alias',lambda a:a['data']['cases'][0].__setitem__('legacyCallsBeforeSynthetic',1)),('non-silent-failure',lambda a:a['data']['cases'][0].__setitem__('silence',False))]:
  b=copy.deepcopy(d)
  try:mutate(b);controls.append({'name':name,'rejected':not verify(b)['passed']})
  except (IndexError,KeyError,TypeError):controls.append({'name':name,'rejected':False,'reason':'missing actual operation'})
 r.update(negativeControls=controls,label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],scope='AudioWorklet constructor/process/missing-process native ErrorEvent, attribute replacement/null/independent removal and silence; MessagePort unhandled exception remains separate')
 if not all(c['rejected'] for c in controls):r['passed']=False;r['issues'].append('negative-control-insensitive')
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
