"""Independent behavioral oracle; availability alone never qualifies an operation."""
import copy, importlib.util, json, math, sys
from pathlib import Path

def module(name, file):
 s=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
lifecycle=module('realm_lifecycle','verify-context-lifecycle.py');png=module('independent_png','verify.py')

def verify(d):
 result=lifecycle.verify(d);issues=result['issues'];checks=result['checks']
 def need(ok,key):
  nonlocal checks
  checks+=1
  if not ok:issues.append(key)
 def pixels(pixel,count):return pixel*count
 receipts=d.get('ownIdentityReceipts',[]);request_nonces=[]
 for i,r in enumerate(d['data']['results']):
  name=r['name'];v=r.get('observation',{}).get('value',{});o=v.get('operations',{})
  need(o.get('errors')==[],name+':operation-errors');need(bool(o),name+':actual-operations')
  if i==4:
   for key in ('canvas','dom','network','audio'):need(o.get(key,{}).get('available') is False,name+':lawful-'+key+'-absence')
   need(o.get('webgl')==[],name+':lawful-webgl-absence')
   p=v.get('processingReceipt',{});need(p.get('calls')==1 and p.get('frame')==0,name+':own-process-frame')
   need(p.get('input')==[.25]*128 and p.get('output')==[.25]*128,name+':actual-process-input-output')
   need(r.get('observation',{}).get('renderedSamples')==[.25]*128,name+':independent-owner-render')
   continue
  c=o.get('canvas',{});need(c.get('available') is True,name+':2d-created')
  expected=pixels([17,34,51,255],12);cleared=expected.copy();cleared[20:28]=[0]*8
  final=cleared.copy();final[24:28]=[128,64,32,255]
  need(c.get('solid')==expected,name+':canvas-solid');need(c.get('repeat')==expected,name+':canvas-repeat')
  need(c.get('crop')==pixels([17,34,51,255],2),name+':canvas-absolute-crop')
  need(c.get('cleared')==cleared,name+':canvas-clear');need(c.get('put')==[128,64,32,255],name+':canvas-put')
  need(c.get('beforeResize')==final,name+':canvas-before-resize');need(c.get('resize')==[0]*48,name+':canvas-resize-reset')
  encoded=c.get('encoded',{});need(encoded.get('type')=='image/png' and type(encoded.get('size')) is int and 0<encoded['size']<4096,name+':actual-PNG-encoding')
  try:w,h,data=png.png_rgba(encoded.get('pngBase64'));decoded=(w,h,list(data))
  except (ValueError,TypeError):decoded=None
  need(decoded==(4,3,final),name+':independent-PNG-pixels')
  # Browser decode is supplementary, never the oracle for PNG correctness.
  need(encoded.get('decoded')==final,name+':browser-bitmap-roundtrip')
  gl=o.get('webgl',[]);need([x.get('kind') for x in gl]==['webgl','webgl2'],name+':two-actual-GL-paths')
  for g in gl:
   prefix=name+':'+str(g.get('kind'));solid=pixels([17,34,51,255],6);scissor=solid.copy();scissor[4:8]=[255,0,0,255]
   need(g.get('available') is True,prefix+':context-created');need(g.get('solid')==solid,prefix+':solid-read')
   need(g.get('repeat')==solid,prefix+':repeat-read');need(g.get('crop')==pixels([17,34,51,255],2),prefix+':absolute-crop')
   need(g.get('scissor')==scissor,prefix+':scissor-coordinate');need(g.get('draw')==pixels([0,255,0,255],6),prefix+':actual-shader-draw')
   need(g.get('linked') is True and g.get('error')==0,prefix+':link-no-error')
   limits=g.get('limits',{});need(type(limits.get('maxTextureSize')) is int and limits['maxTextureSize']>=2048 and isinstance(limits.get('maxViewportDims'),list) and len(limits['maxViewportDims'])==2 and all(type(x) is int and x>=2048 for x in limits['maxViewportDims']),prefix+':valid-native-limits')
  dom=o.get('dom',{});is_window=i in (0,5,6,7,8);need(dom.get('available')==is_window,name+':DOM-availability')
  if is_window:
   box={'x':10,'y':20,'width':31,'height':19};need(dom.get('box')==box and dom.get('repeat')==box,name+':actual-DOM-geometry')
   need(dom.get('rectCount')==1 and dom.get('clientWidth')==31 and dom.get('offsetWidth')==31,name+':DOM-invariants')
  audio=o.get('audio',{});need(audio.get('available')==is_window,name+':Audio-availability')
  if is_window:
   need(audio.get('length')==256 and audio.get('channels')==2 and audio.get('sampleRate')==48000,name+':Audio-buffer-contract')
   need(audio.get('dc')==[[.25]*256,[-.5]*256],name+':Audio-actual-two-channels')
   need(audio.get('silence')==[0]*128,name+':Audio-silence')
  n=o.get('network',{});need(n.get('available') is True,name+':fetch-available');nonce=n.get('requestNonce');request_nonces.append(nonce)
  matches=[x for x in receipts if x.get('requestNonce')==nonce and x.get('realmNonce')==v.get('nonce')]
  need(isinstance(nonce,str) and len(nonce)>10 and len(matches)==1,name+':independent-server-receipt')
  http=n.get('http',{});need(bool(matches) and http==matches[0],name+':unmodified-server-echo')
  headers=http.get('headers',{});need(headers.get('user-agent')==v.get('userAgent'),name+':HTTP-UA')
  langs=v.get('languages',[]);need(isinstance(headers.get('accept-language'),str) and bool(langs) and headers['accept-language'].split(',')[0]==langs[0],name+':HTTP-language')
  for key in ('device-memory','sec-ch-device-memory'):
   hint=headers.get(key)
   if hint is not None:
    try:good=float(hint)==v.get('deviceMemory')
    except ValueError:good=False
    need(good,name+':HTTP-'+key)
 need(len(request_nonces)==8 and len(set(request_nonces))==8,'eight-distinct-realm-native-HTTP-requests')
 return {'passed':not issues,'checks':checks,'issues':issues}

if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);controls=[]
 mutations=[('canvas-crop',lambda x:x['data']['results'][1]['observation']['value']['operations']['canvas']['crop'].__setitem__(0,9)),('shader-draw',lambda x:x['data']['results'][3]['observation']['value']['operations']['webgl'][1]['draw'].__setitem__(0,9)),('missing-operations',lambda x:x['data']['results'][2]['observation']['value'].pop('operations')),('silence-noise',lambda x:x['data']['results'][5]['observation']['value']['operations']['audio']['silence'].__setitem__(0,0.001)),('worklet-audio',lambda x:x['data']['results'][4]['observation']['renderedSamples'].__setitem__(0,0)),('worklet-forged-fetch',lambda x:x['data']['results'][4]['observation']['value']['operations']['network'].__setitem__('available',True)),('server-receipt',lambda x:x['ownIdentityReceipts'].clear()),('request-nonce',lambda x:x['data']['results'][7]['observation']['value']['operations']['network'].__setitem__('requestNonce','wrong')),('corrupt-PNG',lambda x:x['data']['results'][6]['observation']['value']['operations']['canvas']['encoded'].__setitem__('pngBase64','AAAA'))]
 for name,change in mutations:
  bad=copy.deepcopy(d);change(bad);controls.append({'name':name,'rejected':not verify(bad)['passed']})
 bad=copy.deepcopy(d);bad['data']['lifecycle']['receipts']=bad['data']['liveNegativeControl']['receipts'];controls.append({'name':'actual-nine-live-before-teardown','rejected':not verify(bad)['passed'],'actualBrowserControl':True})
 r.update(negativeControls=controls,negativeControlsQualified=r['passed'] and all(x['rejected'] for x in controls),label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],scope='nine independently bound/terminated realms; actual Canvas PNG/WebGL draw/Window+worklet Audio/realm HTTP; not exhaustive per-realm API paths')
 p.with_name(p.stem.replace('-observations','')+'-operations-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] and r['negativeControlsQualified'] else 2)
