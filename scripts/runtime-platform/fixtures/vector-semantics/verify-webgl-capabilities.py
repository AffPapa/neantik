import copy,json,sys,math
from pathlib import Path

def verify(d):
 checks=0;issues=[]
 def need(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup');x=d['data'];need(x.get('errors')==[],'capture-errors');need([c['version'] for c in x['cases']]==[1,2],'version-coverage')
 for c in x['cases']:
  v=c['version'];prefix=str(v)+':';need(c['available'] is True,prefix+'available')
  if not c['available']:continue
  need(len({e['name'] for e in c['extensions']})==len(c['extensions']) and all(e['enabled'] and e['error']==0 for e in c['extensions']),prefix+'advertised-extension-enables')
  need(len(c['precision'])==12 and all(p['error']==0 and all(isinstance(p[f],int) and p[f]>=0 for f in ['rangeMin','rangeMax','precision']) for p in c['precision']),prefix+'precision-query')
  limits=c['limits'];need(limits['maxTextureSize']>=64 and limits['maxRenderbufferSize']>=64 and limits['maxVertexAttribs']>=8 and limits['maxTextureUnits']>=8 and len(limits['maxViewport'])==2 and min(limits['maxViewport'])>=4,prefix+'minimum-capabilities')
  need(c['invalidCompiled'] is False,prefix+'invalid-shader-rejected');m=c['mismatched'];need(m['vertexCompiled'] and m['fragmentCompiled'] and m['linked'] is False and m['error']==0,prefix+'incompatible-link-rejected')
  need(c['incomplete']['status']!=36053 and c['incomplete']['error']==1286 and c['incomplete']['sentinelUnchanged'],prefix+'incomplete-framebuffer')
  if v==2:
   a=c['integer'];need(a['complete'] and a['readError']==0 and a['pixels']==[17,29,43,255]*16,prefix+'integer-operation');need(a['wrongFormatError']==1282 and a['wrongFormatUnchanged'],prefix+'integer-format-error')
   a=c['multisample'];need(a['advertised'] is True,prefix+'msaa-advertised')
   if a['advertised']:need(a['complete'] and a['samples']>0 and a['directError']==1282 and a['directUnchanged'] and a['blitError']==0 and a['readError']==0 and a['pixels']==[255,0,0,255]*16,prefix+'msaa-resolve')
   a=c['float'];need(isinstance(a['advertised'],bool),prefix+'float-status')
   if a['advertised']:need(a['complete'] and a['readError']==0 and len(a['pixels'])==64 and all(abs(z-e)<=1e-6 for z,e in zip(a['pixels'],[.25,-.5,2,1]*16)),prefix+'advertised-float-operation')
  a=c['restored'];need(a['advertised'] is True,prefix+'loss-extension')
  if a['advertised']:need(a['lostEvent']=='webglcontextlost' and a['restoreEvent']=='webglcontextrestored' and a['wasLost'] and a['lostError']==37442 and a['isLostAfter'] is False and a['oldTextureInvalid'] and a['complete'] and a['pixels']==[0,255,0,255]*16 and a['readError']==0,prefix+'restored-operation')
  need(c['finalError']==0,prefix+'final-error')
 return {'checks':checks,'issues':issues,'passed':not issues}

if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);controls=[]
 for name,mutate in [('advertised-extension-broken',lambda a:a['data']['cases'][0]['extensions'][0].__setitem__('enabled',False)),('bad-shader-accepted',lambda a:a['data']['cases'][0].__setitem__('invalidCompiled',True)),('bad-link-accepted',lambda a:a['data']['cases'][0]['mismatched'].__setitem__('linked',True)),('framebuffer-error-swallowed',lambda a:a['data']['cases'][0]['incomplete'].__setitem__('error',0)),('integer-corruption',lambda a:a['data']['cases'][1]['integer']['pixels'].__setitem__(0,0)),('restore-event-missing',lambda a:a['data']['cases'][0]['restored'].__setitem__('restoreEvent',None)),('msaa-resolve-broken',lambda a:a['data']['cases'][1]['multisample']['pixels'].__setitem__(0,0))]:
  b=copy.deepcopy(d)
  try:mutate(b);controls.append({'name':name,'rejected':not verify(b)['passed']})
  except (IndexError,KeyError,TypeError):controls.append({'name':name,'rejected':False,'reason':'missing actual operation'})
 r.update(negativeControls=controls,label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],scope='WebGL capability queries, extension enablement, invalid shaders/link/FBO, integer/float/MSAA operations and actual loss/restore; GPU-name vs hardware compatibility remains separate')
 if not all(c['rejected'] for c in controls):r['passed']=False;r['issues'].append('negative-control-insensitive')
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
