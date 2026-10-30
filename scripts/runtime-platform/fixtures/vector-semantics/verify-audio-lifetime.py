import copy,json,sys
from pathlib import Path

def verify(d):
 checks=0;issues=[]
 def need(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup')
 x=d['data'];need(x.get('errors')==[],'capture-errors');need([c['mode'] for c in x['cases']]==['generator-first','generator-repeat','throws'],'mode-coverage')
 for c in x['cases']:
  mode=c['mode'];need(c['renderCompleted'] and c['state']=='closed' and c['portClosed'] and c['disconnected'],mode+':completion')
  need(c['processorErrors']==(1 if mode=='throws' else 0),mode+':processor-error-property')
  need(c['processorListenerErrors']==(1 if mode=='throws' else 0) and all(t=='processorerror' for t in c['processorEventTypes']),mode+':processor-error-event')
  need(c['terminal'] is None if mode=='throws' else c['terminal']=={'terminal':True,'calls':32,'frames':4096},mode+':finite-generator')
  need([a['channel'] for a in c['channels']]==[0,1],mode+':channels')
  for a in c['channels']:need(a['length']==8192 and a['maxError']<=1e-6 and a['tailMax']==0,mode+':output-'+str(a['channel']))
 if len(x['cases'])>=2:need(x['cases'][0]['channels']==x['cases'][1]['channels'],'generator-repeat-exact')
 return {'checks':checks,'issues':issues,'passed':not issues}

if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);r['negativeControlsQualified']=r['passed'];controls=[]
 for name,mutate in [('generator-not-stopped',lambda a:a['data']['cases'][0]['channels'][0].__setitem__('tailMax',0.2)),('channel-clamped',lambda a:a['data']['cases'][0]['channels'][1].__setitem__('maxError',1)),('quantum-skipped',lambda a:a['data']['cases'][0]['terminal'].__setitem__('calls',31)),('processor-error-lost',lambda a:a['data']['cases'][2].__setitem__('processorErrors',0)),('throw-not-silenced',lambda a:a['data']['cases'][2]['channels'][0].__setitem__('maxError',0.1))]:
  b=copy.deepcopy(d)
  try:mutate(b);controls.append({'name':name,'rejected':not verify(b)['passed']})
  except (IndexError,KeyError,TypeError):controls.append({'name':name,'rejected':False,'reason':'missing actual operation receipt'})
 r.update(negativeControls=controls,label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],scope='Finite zero-input worklet generator, repeat, deliberate processorerror and output silence; physical worklet-thread destruction not inferred')
 if not all(c['rejected'] for c in controls):r['passed']=False;r['issues'].append('negative-control-insensitive')
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
