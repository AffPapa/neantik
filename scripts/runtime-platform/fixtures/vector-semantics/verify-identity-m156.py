"""Exact M156 identity oracle with fresh headed ordinary Chrome155 control.
Derived from unchanged own oracle SHA c9eadde3d47c30c47cbcd0549b1e0902a1f9b5705f5f50dffd65393ff374b81f.
Only control version/path and contradictory negative value were refreshed.
"""
import copy,json,re,sys
from pathlib import Path
import os
def sf_string(v):
 try:return json.loads(v) if isinstance(v,str) else None
 except (ValueError,TypeError):return None
def brands(v):
 if not isinstance(v,str):return None
 pattern=r'("(?:[^"\\]|\\.)*");v=("(?:[^"\\]|\\.)*")'
 result=[];end=0
 for m in re.finditer(pattern,v):
  if v[end:m.start()].strip() not in ('',','):return None
  result.append({'brand':sf_string(m[1]),'version':sf_string(m[2])});end=m.end()
 if v[end:].strip() or not result:return None
 return result
def verify(d,worker_reference=None):
 issues=[];checks=0;unavailable=[]
 def need(ok,key):
  nonlocal checks
  checks+=1
  if not ok:issues.append(key)
 need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup');need(d.get('documentEvidence',{}).get('loaded') is True,'own-response-document')
 for key in ('page','redirect','worker'):
  x=d['data'].get(key,{})
  if x.get('error'):need(False,key+':actual-operation');continue
  js=x.get('js',{});h=x.get('http',{}).get('headers',{});hint=js.get('hints',{})
  need(isinstance(js.get('userAgent'),str) and bool(js['userAgent']) and h.get('user-agent')==js['userAgent'],key+':UA')
  languages=js.get('languages',[]);parsed=[v.split(';')[0].strip() for v in (h.get('accept-language') or '').split(',')]
  need(bool(languages) and all(isinstance(v,str) and bool(v) for v in languages) and parsed[:len(languages)]==languages,key+':languages')
  # M154/155/156 desktop now clamp approximate memory to 2..32 GB. NeAntik's
  # seeded public value is 8; physical RAM, heap and quota are separate signals.
  need(type(js.get('deviceMemory')) in (int,float) and js['deviceMemory'] in (2,4,8,16,32),key+':memory-value')
  if key=='worker' and worker_reference is not None:
   expected=worker_reference['data']['worker']['http']['headers']
   optional=[k for k in expected if k.startswith('sec-ch-') or k=='device-memory']
   need(worker_reference.get('documentEvidence',{}).get('loaded') is True and worker_reference.get('cleanupVerified') is True and worker_reference['runtimeVersion']=='155.0.8059.39' and all(expected[k] is None for k in optional),'ordinary-Chrome-worker-absence-control')
   need(all(h.get(k) is None for k in optional),key+':observed-upstream-hint-availability')
   need(js==d['data']['js'],key+':actual-js-identity-vs-page')
   need(x.get('http',{}).get('via')==key,key+':request-path')
   unavailable.extend(key+':'+k for k in optional)
   continue
  need(h.get('device-memory')==str(js['deviceMemory']) and h.get('sec-ch-device-memory')==str(js['deviceMemory']),key+':memory')
  for header,field in [('sec-ch-ua-platform','platform'),('sec-ch-ua-arch','architecture'),('sec-ch-ua-bitness','bitness'),('sec-ch-ua-platform-version','platformVersion')]:need(isinstance(hint.get(field),str) and bool(hint[field]) and sf_string(h.get(header))==hint[field],key+':'+field)
  need(type(hint.get('mobile')) is bool and h.get('sec-ch-ua-mobile')==('?1' if hint.get('mobile') else '?0'),key+':mobile')
  need(brands(h.get('sec-ch-ua'))==hint.get('brands') and isinstance(hint.get('brands'),list) and bool(hint['brands']),key+':brands')
  need(brands(h.get('sec-ch-ua-full-version-list'))==hint.get('fullVersionList') and isinstance(hint.get('fullVersionList'),list) and bool(hint['fullVersionList']),key+':fullVersionList')
  need(x.get('http',{}).get('via')==key,key+':request-path')
 return {'checks':checks,'issues':issues,'passed':not issues,'unavailableSignals':unavailable}
if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());reference=json.loads(p.with_name('m156-control-fresh-chrome-identity-observations.json').read_text());binding=json.loads(Path(os.environ['NEANTIK_PLATFORM_BINDING']).read_text());assert d['runtimeVersion']==binding['runtimeVersion'] and d['executableSHA256']==binding['runtimeExecutableSHA256'] and d['runtimeFrameworkSHA256']==binding['runtimeFrameworkSHA256'];r=verify(d,reference);neg=[]
 for label,mutate in [('memory-contradiction',lambda a:a['data']['page']['http']['headers'].__setitem__('sec-ch-device-memory','4' if a['data']['page']['js']['deviceMemory']!=4 else '8')),('UA-mismatch',lambda a:a['data']['worker']['http']['headers'].__setitem__('user-agent','contradiction')),('lang-mismatch',lambda a:a['data']['redirect']['http']['headers'].__setitem__('accept-language','xx')),('full-version-mismatch',lambda a:a['data']['page']['http']['headers'].__setitem__('sec-ch-ua-full-version-list','"Chromium";v="1.0"')),('unexpected-worker-hint',lambda a:a['data']['worker']['http']['headers'].__setitem__('sec-ch-device-memory','32')),('missing-operation',lambda a:a['data'].__setitem__('worker',{'error':'timeout'}))]:
  a=copy.deepcopy(d);mutate(a);neg.append({'name':label,'rejected':not verify(a,reference)['passed']})
 r.update(workerReferenceSHA256=__import__('hashlib').sha256(p.with_name('m156-control-fresh-chrome-identity-observations.json').read_bytes()).hexdigest(),negativeControls=neg,negativeControlsQualified=r['passed'] and all(x['rejected'] for x in neg),label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256']);p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
