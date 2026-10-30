import copy,json,sys
from pathlib import Path
def verify(document):
 issues=[];checks=0
 def require(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 require(document.get('headed') is True and document.get('cleanupVerified') is True,'headed-cleanup')
 d=document['data'];require(d.get('errors')==[],'capture-errors')
 require([x.get('version') for x in d.get('cases',[])]==[1,2],'both-versions')
 def grid(w,h,x=0,y=0):return [v for yy in range(y,y+h) for xx in range(x,x+w) for v in (17+xx*13,23+yy*19,31+(xx+yy)*7,255)]
 for c in d.get('cases',[]):
  v=c['version'];require(c.get('available') is True,f'{v}:available')
  if not c.get('available'):continue
  w,h=c['width'],c['height'];require((w,h)==(8,6),f'{v}:geometry')
  require(c['complete'] and c['setupError']==0,f'{v}:framebuffer')
  calls={x['name']:x for x in c['calls']};expected={'full':grid(w,h),'repeat':grid(w,h),'crop':grid(3,2,2,1),'zero':[165]*12,'short':[165]*4,'transparent':[0]*(w*h*4)}
  if v==2:
   expected['dst-offset']=[165]*7+grid(w,h)+[165]*11
   packed=[165]*160
   for yy in range(2):packed[5+32*(1+yy)+4:5+32*(1+yy)+4+12]=grid(3,1,2,1+yy)
   expected['packed']=packed;expected['pbo']=[165]*16+grid(w,h)+[165]*12
   expected['typed-with-pbo']=[165]*(w*h*4)
  for name,values in expected.items():
   require(name in calls,f'{v}:{name}:receipt')
   if name not in calls:continue
   require(calls[name].get('bytes')==values,f'{v}:{name}:bytes')
   require(calls[name]['error']==(1282 if name in ['short','typed-with-pbo'] else 0),f'{v}:{name}:error')
  if v==2:require(calls.get('offset-without-pbo',{}).get('error')==1282,'2:offset-without-pbo')
  require(c['shaderCompiled'] and c['linked'],f'{v}:shader-real-compile-link')
  require(c.get('draw',{}).get('bytes')==[255,0,0,255]*(w*h) and c.get('draw',{}).get('error')==0,f'{v}:shader-draw')
  require(c['finalError']==0,f'{v}:final-error')
  if v==2:require(calls.get('pbo',{}).get('bytes',[])[16:16+w*h*4]==calls.get('full',{}).get('bytes'),'2:typed-pbo')
 return {'checks':checks,'issues':issues,'passed':not issues}
if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);r.update(label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],scope='readPixels/pack/PBO/framebuffer/shader semantics; full capability compatibility remains open')
 if '--negative-controls' in sys.argv:
  negatives=[]
  for name,mutate in [('payload',lambda a:a['data']['cases'][0]['calls'][0]['bytes'].__setitem__(0,0)),('padding',lambda a:next(x for x in a['data']['cases'][1]['calls'] if x['name']=='packed')['bytes'].__setitem__(0,0)),('crop',lambda a:next(x for x in a['data']['cases'][0]['calls'] if x['name']=='crop')['bytes'].__setitem__(0,0)),('pbo',lambda a:next(x for x in a['data']['cases'][1]['calls'] if x['name']=='pbo')['bytes'].__setitem__(16,0)),('error',lambda a:next(x for x in a['data']['cases'][1]['calls'] if x['name']=='typed-with-pbo').__setitem__('error',0)),('shader',lambda a:a['data']['cases'][0].__setitem__('linked',False))]:
   a=copy.deepcopy(d);mutate(a);negatives.append({'name':name,'rejected':not verify(a)['passed']})
  r['negativeControls']=negatives
  assert all(x['rejected'] for x in negatives)
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
