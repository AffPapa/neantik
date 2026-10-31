"""Exact M156 identity oracle with fresh headed ordinary Chrome155 control.
Derived from unchanged own oracle SHA c9eadde3d47c30c47cbcd0549b1e0902a1f9b5705f5f50dffd65393ff374b81f.
The ordinary Chrome control is independently bound; absent keys are not observations.
"""
import copy,hashlib,json,re,sys
from pathlib import Path
import os
POLICY_PATH=Path(__file__).with_name('identity-reference-policy.json')
POLICY=json.loads(POLICY_PATH.read_text())
ABSENT_HEADERS=tuple(POLICY['absentWorkerHeaders'])
def reference_valid(reference,binding,binding_sha):
 if not isinstance(reference,dict) or not isinstance(binding,dict):return False
 document=reference.get('documentEvidence');data=reference.get('data')
 if not isinstance(document,dict) or not isinstance(data,dict):return False
 if (binding.get('runtimeVersion')!=POLICY['runtimeVersion'] or
     binding.get('policySHA256')!=hashlib.sha256(POLICY_PATH.read_bytes()).hexdigest() or
     not isinstance(binding_sha,str) or not re.fullmatch('[0-9a-f]{64}',binding_sha) or
     reference.get('candidateBindingSHA256')!=binding_sha or
     reference.get('headed') is not True or reference.get('cleanupVerified') is not True or
     document.get('loaded') is not True or
     reference.get('mode')!=POLICY['mode'] or reference.get('label')!=POLICY['label']):return False
 for actual,expected in [('runtimeVersion','runtimeVersion'),('executableSHA256','runtimeExecutableSHA256'),('runtimeFrameworkSHA256','runtimeFrameworkSHA256')]:
  if reference.get(actual)!=binding.get(expected):return False
 for field in ('runtimeExecutableSHA256','runtimeFrameworkSHA256'):
  if not isinstance(binding.get(field),str) or not re.fullmatch('[0-9a-f]{64}',binding[field]):return False
 worker=data.get('worker')
 if not isinstance(worker,dict):return False
 js=worker.get('js');http=worker.get('http')
 if not isinstance(js,dict) or not isinstance(http,dict):return False
 h=http.get('headers');languages=js.get('languages')
 if not isinstance(h,dict) or not isinstance(languages,list) or not languages or not all(isinstance(x,str) and x for x in languages) or not isinstance(h.get('accept-language'),str):return False
 return (not worker.get('error') and http.get('via')=='worker' and
         isinstance(js.get('userAgent'),str) and bool(js['userAgent']) and h.get('user-agent')==js['userAgent'] and
         h['accept-language'].split(',')[0]==languages[0] and
         js==data.get('js') and all(k in h and h[k] is None for k in ABSENT_HEADERS))
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
def verify(d,worker_reference=None,reference_binding=None,reference_binding_sha=None):
 issues=[];checks=0;unavailable=[]
 def need(ok,key):
  nonlocal checks
  checks+=1
  if not ok:issues.append(key)
 need(reference_valid(worker_reference,reference_binding,reference_binding_sha),'ordinary-Chrome-bound-reference')
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
  if key=='worker':
   need(all(k in h and h[k] is None for k in ABSENT_HEADERS),key+':observed-upstream-hint-availability')
   need(js==d['data']['js'],key+':actual-js-identity-vs-page')
   need(x.get('http',{}).get('via')==key,key+':request-path')
   unavailable.extend(key+':'+k for k in ABSENT_HEADERS)
   continue
  need(h.get('device-memory')==str(js.get('deviceMemory')) and h.get('sec-ch-device-memory')==str(js.get('deviceMemory')),key+':memory')
  for header,field in [('sec-ch-ua-platform','platform'),('sec-ch-ua-arch','architecture'),('sec-ch-ua-bitness','bitness'),('sec-ch-ua-platform-version','platformVersion')]:need(isinstance(hint.get(field),str) and bool(hint[field]) and sf_string(h.get(header))==hint[field],key+':'+field)
  need(type(hint.get('mobile')) is bool and h.get('sec-ch-ua-mobile')==('?1' if hint.get('mobile') else '?0'),key+':mobile')
  need(brands(h.get('sec-ch-ua'))==hint.get('brands') and isinstance(hint.get('brands'),list) and bool(hint['brands']),key+':brands')
  need(brands(h.get('sec-ch-ua-full-version-list'))==hint.get('fullVersionList') and isinstance(hint.get('fullVersionList'),list) and bool(hint['fullVersionList']),key+':fullVersionList')
  need(x.get('http',{}).get('via')==key,key+':request-path')
 return {'checks':checks,'issues':issues,'passed':not issues,'unavailableSignals':unavailable}
if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());reference_path=p.with_name('m156-control-fresh-chrome-identity-observations.json');reference=json.loads(reference_path.read_text());binding=json.loads(Path(os.environ['NEANTIK_PLATFORM_BINDING']).read_text());assert d['runtimeVersion']==binding['runtimeVersion'] and d['executableSHA256']==binding['runtimeExecutableSHA256'] and d['runtimeFrameworkSHA256']==binding['runtimeFrameworkSHA256'];rb_path=Path(os.environ['NEANTIK_PLATFORM_CHROME_REFERENCE_BINDING']);rb=json.loads(rb_path.read_text());rb_sha=hashlib.sha256(rb_path.read_bytes()).hexdigest();r=verify(d,reference,rb,rb_sha);neg=[]
 if not r['passed']:
  r.update(negativeControls=[],negativeControlsQualified=False);print(json.dumps(r));sys.exit(2)
 for label,mutate in [('memory-contradiction',lambda a:a['data']['page']['http']['headers'].__setitem__('sec-ch-device-memory','4' if a['data']['page']['js']['deviceMemory']!=4 else '8')),('UA-mismatch',lambda a:a['data']['worker']['http']['headers'].__setitem__('user-agent','contradiction')),('lang-mismatch',lambda a:a['data']['redirect']['http']['headers'].__setitem__('accept-language','xx')),('full-version-mismatch',lambda a:a['data']['page']['http']['headers'].__setitem__('sec-ch-ua-full-version-list','"Chromium";v="1.0"')),('unexpected-worker-hint',lambda a:a['data']['worker']['http']['headers'].__setitem__('sec-ch-device-memory','32')),('missing-operation',lambda a:a['data'].__setitem__('worker',{'error':'timeout'}))]:
  a=copy.deepcopy(d);mutate(a);neg.append({'name':label,'rejected':not verify(a,reference,rb,rb_sha)['passed']})
 for label,mutate in [('missing-reference-headers',lambda a:a['data']['worker']['http'].__setitem__('headers',{})),('wrong-reference-runtime',lambda a:a.__setitem__('runtimeVersion','155.0.8059.39')),('reference-timeout',lambda a:a['data'].__setitem__('worker',{'error':'timeout'})),('wrong-reference-binding',lambda a:a.__setitem__('candidateBindingSHA256','0'*64))]:
  a=copy.deepcopy(reference);mutate(a);neg.append({'name':label,'rejected':not verify(d,a,rb,rb_sha)['passed']})
 a=copy.deepcopy(d);a['data']['worker']['http']['headers'].pop(ABSENT_HEADERS[0]);neg.append({'name':'missing-candidate-header','rejected':not verify(a,reference,rb,rb_sha)['passed']})
 r.update(workerReferenceSHA256=__import__('hashlib').sha256(p.with_name('m156-control-fresh-chrome-identity-observations.json').read_bytes()).hexdigest(),negativeControls=neg,negativeControlsQualified=r['passed'] and all(x['rejected'] for x in neg),label=d['label'],runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256']);p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
