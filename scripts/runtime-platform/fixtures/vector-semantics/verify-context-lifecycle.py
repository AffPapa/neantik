import copy,json,sys
from pathlib import Path
import importlib.util
spec=importlib.util.spec_from_file_location('basic_contexts',Path(__file__).with_name('verify-contexts.py'));basic=importlib.util.module_from_spec(spec);spec.loader.exec_module(basic)

def verify(d):
 r=basic.verify(d);issues=r['issues'];checks=r['checks']
 def need(ok,key):
  nonlocal checks
  checks+=1
  if not ok:issues.append(key)
 data=d['data'];life=data.get('lifecycle',{});receipts=life.get('receipts',[])
 need(life.get('recorderErrors')==[],'recorder-completed-without-errors')
 need([x.get('name') for x in receipts]==basic.NAMES,'nine-independent-lifecycle-receipts')
 if len(receipts)==9:
  for name,receipt,realm in zip(basic.NAMES,receipts,data['results']):
   need(receipt.get('confirmed') is True and receipt.get('uniqueContext') is True and realm['observation'].get('lifecycleCreation',{}).get('confirmed') is True,name+':independent-creation')
   allowed={'page':'target-destroyed','DedicatedWorker':'target-destroyed','SharedWorker':'shared-worker-host-destroyed-notification','ServiceWorker':'observed-service-worker-stopped','AudioWorklet':'target-destroyed','same-origin iframe':'context-destroyed','about:blank iframe':'context-destroyed','srcdoc iframe':'context-destroyed','cross-origin OOPIF':'target-destroyed'}
   need(receipt.get('terminated') is True and receipt.get('mechanism')==allowed[name],name+':actual-individual-teardown')
   if name=='ServiceWorker':need(receipt.get('versionBound') is True,name+':recorded-running-version')
 closure=d.get('browserClosure',{});need(closure.get('gracefulParentExit') is True and closure.get('parentExitCode')==0 and closure.get('parentSignal') is None,'normal-parent-exit-no-force')
 return {'passed':not issues,'checks':checks,'issues':issues}
if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d);negative=copy.deepcopy(d);negative['data']['lifecycle']['receipts']=negative['data']['liveNegativeControl']['receipts'];live=negative['data']['lifecycle']['receipts'];actual={'name':'actual-live-contexts-before-teardown','allNineIndependentlyRecorded':len(live)==9 and all(x['confirmed'] for x in live),'liveBoundariesObserved':sum(not x['terminated'] for x in live),'rejected':not verify(negative)['passed']}
 r['actualNegativeControl']=actual;r['negativeControlsQualified']=r['passed'] and actual['allNineIndependentlyRecorded'] and actual['liveBoundariesObserved']==9 and actual['rejected'];r.update(label=d['label'],executableSHA256=d['executableSHA256'],runtimeVersion=d['runtimeVersion'],scope='actual nine-context creation/basic identity/Intl and independent individual teardown; complete per-realm API operation coverage remains open');p.with_name(p.stem.replace('-observations','')+'-lifecycle-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] and r['negativeControlsQualified'] else 2)
