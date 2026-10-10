"""Native headed operations, semantic geometry, and independent corruptions.
Screen values are persona attributes; do not equate them to native window bounds.
"""
import copy,hashlib,json,math,sys
from pathlib import Path
import os
def candidate_binding():
 return json.loads(Path(os.environ["NEANTIK_PLATFORM_BINDING"]).read_text())
KEYS=('x','y','left','top','right','bottom','width','height')
def verify(d):
 issues=[];checks=0
 def need(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 def near(a,b):return isinstance(a,(int,float)) and math.isfinite(a) and abs(a-b)<=1e-5
 def valid(r,name):
  need(isinstance(r,dict),name+':rect')
  if not isinstance(r,dict):return False
  finite=all(isinstance(r.get(k),(int,float)) and math.isfinite(r[k]) for k in KEYS)
  need(finite,name+':finite')
  if finite:
   for key,expected in [('x',r['left']),('y',r['top']),('width',r['right']-r['left']),('height',r['bottom']-r['top'])]:need(near(r[key],expected),name+':'+key)
   need(r['width']>=0 and r['height']>=0,name+':nonnegative')
  return finite
 def union(v,name):
  rs=v.get('clients',[]);need(bool(rs),name+':clients')
  for i,r in enumerate(rs):valid(r,name+':client'+str(i))
  if not valid(v.get('bounding'),name+':bounding') or not rs:return
  nonempty=[r for r in rs if r['width']>0 and r['height']>0]
  if nonempty:
   expected={'left':min(r['left'] for r in nonempty),'top':min(r['top'] for r in nonempty),'right':max(r['right'] for r in nonempty),'bottom':max(r['bottom'] for r in nonempty)}
  else:expected={k:rs[0][k] for k in ('left','top','right','bottom')}
  for k,a in expected.items():need(near(v['bounding'][k],a),name+':union:'+k)
 need(d.get('runtimeVersion')==candidate_binding()['runtimeVersion'] and d.get('executableSHA256')==candidate_binding()['runtimeExecutableSHA256'] and d.get('runtimeFrameworkSHA256')==candidate_binding()['runtimeFrameworkSHA256'],'exact-m156-runtime')
 need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup')
 need(d.get('documentEvidence',{}).get('loaded') is True,'document-loaded')
 need(d.get('browserClosure',{}).get('gracefulParentExit') is True,'graceful-close')
 need(d.get('fixtureSourceArchive',{}).get('manifestSHA256')==d.get('fixtureProvenance',{}).get('manifestSHA256'),'source-binding')
 samples=d.get('data',{}).get('samples',[]);need([s.get('step') for s in samples]==['initial','wide','narrow','fullscreen','restored'],'all-native-operations')
 if len(samples)!=5:return {'checks':checks,'issues':issues,'passed':False}
 screens=[]
 zoom=d.get('zoomPreferenceReceipt',{}).get('zoomFactor');need(zoom in (1,1.25),'native-zoom-receipt')
 files={x['path']:x['sha256'] for x in d.get('fixtureProvenance',{}).get('files',[])}
 need(files.get('vector-semantics/window-geometry-probe.js')==d.get('probeSHA256'),'probe-binding')
 need(files.get('vector-semantics/run-headed-m156-window.mjs')==d.get('runnerSHA256'),'runner-binding')
 for s in samples:
  n=s['step'];v=s['data'];screens.append(v['screen'])
  for phase in ('before','after','translated'):
   a=v[phase];dx,dy=(32,16) if phase=='translated' else (0,0)
   expected={'x':101+dx-a['scrollX'],'left':101+dx-a['scrollX'],'right':304+dx-a['scrollX'],'y':8000+dy-a['scrollY'],'top':8000+dy-a['scrollY'],'bottom':8037+dy-a['scrollY'],'width':203,'height':37}
   rs=[a['bounding'],a['client'],a['range']['bounding'],*a['range']['clients']]
   need(len(a['range']['clients'])==1,n+':'+phase+':box-fragments')
   for i,r in enumerate(rs):
    valid(r,n+':'+phase+':'+str(i))
    for k,x in expected.items():need(near(r.get(k),x),n+':'+phase+':'+str(i)+':'+k)
  text=v['textBefore'];need(text==v['textRepeat'],n+':repeat')
  for kind in ('all','line1','line2','caret','span'):union(text[kind],n+':'+kind)
  need(len(text['line1']['clients'])==1 and len(text['line2']['clients'])==1,n+':two-text-lines')
  need(near(text['line2']['bounding']['top']-text['line1']['bounding']['top'],24),n+':line-height')
  caret=text['caret']['bounding'];line=text['line1']['bounding']
  need(near(caret['width'],0) and caret['height']>0 and line['left']<=caret['left']<=line['right'],n+':collapsed-range')
  need(v['textWidths'][0]>0 and near(*v['textWidths']),n+':measuretext-repeat')
  need(v.get('widthMediaIntegerTolerance')==0.5,n+':width-integer-quantization');need(all(v['media'].values()),n+':css-media')
  viewport=v['viewport'];need(near(viewport['dpr'],2*zoom),n+':native-dpr-zoom');need(viewport['innerWidth']>0 and viewport['innerHeight']>0 and viewport['dpr']>0,n+':viewport-positive')
  need(viewport['scrollbarWidth']>=0,n+':scrollbar')
  sc=v['screen'];need(0<sc['availWidth']<=sc['width'] and 0<sc['availHeight']<=sc['height'],n+':available-screen')
  need(sc['pixelDepth']==sc['colorDepth'],n+':depth')
 need(all(s==screens[0] for s in screens),'screen-stable-resize-fullscreen')
 wide,narrow=samples[1],samples[2]
 need(wide['bounds']['width']==1100 and wide['bounds']['height']==800,'native-wide')
 need(narrow['bounds']['width']==760 and narrow['bounds']['height']==620,'native-narrow')
 for k in ('innerWidth','innerHeight','outerWidth','outerHeight'):need(wide['data']['viewport'][k]>narrow['data']['viewport'][k],'responsive:'+k)
 need(narrow['data']['resizeEvents']>wide['data']['resizeEvents'],'resize-event')
 need(samples[3]['data']['fullscreen'] is True and samples[4]['data']['fullscreen'] is False,'fullscreen-state')
 need(samples[3]['data']['fullscreenEvents']>=1 and samples[4]['data']['fullscreenEvents']>samples[3]['data']['fullscreenEvents'],'fullscreen-events')
 for k in ('innerWidth','innerHeight','outerWidth','outerHeight','dpr'):need(near(samples[4]['data']['viewport'][k],narrow['data']['viewport'][k]),'fullscreen-restored:'+k)
 return {'checks':checks,'issues':issues,'passed':not issues}
if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);r.update(runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],observationSHA256=hashlib.sha256(p.read_bytes()).hexdigest(),scope='Actual headed native window resize, fullscreen entry/exit, native page zoom, CSS/DOMRect/Range/scroll/transform/repeated text; no second display or final manager qualification.')
 controls=[('wrong-runtime',lambda a:a.__setitem__('executableSHA256','0'*64)),('wrong-zoom',lambda a:a['zoomPreferenceReceipt'].__setitem__('zoomFactor',0.8)),('source-drift',lambda a:a.__setitem__('runnerSHA256','0'*64)),('range-union',lambda a:a['data']['samples'][0]['data']['textBefore']['all']['bounding'].__setitem__('width',1)),('collapsed-width',lambda a:a['data']['samples'][0]['data']['textBefore']['caret']['bounding'].__setitem__('width',10)),('crop-scroll',lambda a:a['data']['samples'][0]['data']['after']['bounding'].__setitem__('x',999)),('fullscreen-state',lambda a:a['data']['samples'][3]['data'].__setitem__('fullscreen',False)),('fullscreen-event',lambda a:a['data']['samples'][4]['data'].__setitem__('fullscreenEvents',0)),('static-window',lambda a:a['data']['samples'][2]['data'].__setitem__('viewport',copy.deepcopy(a['data']['samples'][1]['data']['viewport']))),('media-dpr',lambda a:a['data']['samples'][0]['data']['media'].__setitem__('dpr',False)),('cleanup',lambda a:a.__setitem__('cleanupVerified',False)),('missing-operation',lambda a:a['data']['samples'].pop())]
 r['negativeControls']=[]
 for name,mutate in controls:
  a=copy.deepcopy(d);mutate(a);r['negativeControls'].append({'name':name,'rejected':not verify(a)['passed']})
 assert all(x['rejected'] for x in r['negativeControls'])
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
