import copy,hashlib,json,math,sys
from pathlib import Path
def verify(d):
 checks=0;issues=[]
 def need(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 v=d['data'];need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup');need(v['fontSHA256']==hashlib.sha256(Path(__file__).with_name('own-ahem.woff2').read_bytes()).hexdigest(),'exact-font-bytes');need(v['fontLoaded'] is True and v.get('worker',{}).get('fontLoaded') is True,'both-font-load-receipts');need(v.get('error') is None and 'error' not in v.get('worker',{}),'worker-completed')
 fields=['width','actualBoundingBoxLeft','actualBoundingBoxRight','actualBoundingBoxAscent','actualBoundingBoxDescent','fontBoundingBoxAscent','fontBoundingBoxDescent']
 for realm in ('page','repeat','offscreen','worker'):
  values=v.get('worker',{}).get('metrics',{}) if realm=='worker' else v.get(realm,{})
  need(isinstance(values.get('width'),(float,int)) and abs(values['width']-100)<1e-7,realm+':known-advance')
  for field in fields:need(field in values and math.isfinite(values[field]) and abs(values[field]-v['page'][field])<1e-7,realm+':'+field)
 return {'checks':checks,'issues':issues,'passed':not issues}
if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);r.update(label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],scope='Identical SHA-bound loaded Ahem font operations in Window Canvas/main Offscreen/DedicatedWorker Offscreen; extended TextMetrics unverified.')
 if '--negative-controls' in sys.argv:
  r['negativeControls']=[]
  for name,mutate in [('wrong-font',lambda a:a['data'].__setitem__('fontSHA256','0'*64)),('missing-worker-load',lambda a:a['data']['worker'].__setitem__('fontLoaded',False)),('worker-width',lambda a:a['data']['worker']['metrics'].__setitem__('width',99)),('ascent',lambda a:a['data']['offscreen'].__setitem__('actualBoundingBoxAscent',99)),('capture-error',lambda a:a['data'].__setitem__('error','Timeout'))]:
   a=copy.deepcopy(d);mutate(a);r['negativeControls'].append({'name':name,'rejected':not verify(a)['passed']})
  assert all(x['rejected'] for x in r['negativeControls'])
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
