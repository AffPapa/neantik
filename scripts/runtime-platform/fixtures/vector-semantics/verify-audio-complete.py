import copy,json,sys,math
from pathlib import Path

def verify(d):
 checks=0;issues=[]
 def need(ok,name):
  nonlocal checks
  checks+=1
  if not ok:issues.append(name)
 need(d.get('headed') is True and d.get('cleanupVerified') is True,'headed-cleanup')
 data=d['data'];need(data.get('errors')==[],'capture-errors')
 need([a['signal'] for a in data.get('analysers',[])]==['silence','positive-dc','negative-dc','sine'],'signal-coverage')
 for a in data.get('analysers',[]):
  s=a['signal'];need(a['renderCompleted'] and a['state']=='closed' and a['length']==8192 and a['sampleRate']==48000,s+':render-completed')
  need([c['channel'] for c in a['channels']]==[0],s+':channels')
  for c in a['channels']:need(c['length']==8192 and c['maxError']<=1e-6 and c['repeatEqual'],s+':render-channel-'+str(c['channel']))
  need(a['timeRepeat'],s+':time-repeat');need(a['frequencyRepeat'],s+':frequency-repeat');need(a['frequencyFiniteOrNegativeInfinity'],s+':frequency-finite')
  # Mono analyser: known signal avoids inferring stereo downmix rules.
  if s!='sine':
   expected={'silence':0,'positive-dc':2,'negative-dc':-2}[s]
   need(all(abs(x-expected)<=1e-6 for x in a['floatTail']),s+':unclamped-float')
   expectedByte=128 if s=='silence' else 255 if s=='positive-dc' else 0
   need(a['byteTail']==[expectedByte]*16,s+':clipped-byte')
  else:
   need(a['peakBin']==32 and a['peakDB'] is not None and -27<a['peakDB']<-18,s+':real-fft-known-frequency')
  if s=='silence':need(a['frequencyAllNegativeInfinity'] and a['byteFrequencyAllZero'],'silence:frequency-native-zero')
 w=data.get('worklet');need(isinstance(w,dict),'worklet:receipt')
 if isinstance(w,dict):
  need(w['moduleLoaded'] and w['renderCompleted'] and w['state']=='closed','worklet:completed')
  need(w['receipt'].get('terminal') is True and w['receipt'].get('frames')==8192 and w['receipt'].get('calls')==64 and w['receipt'].get('rate')==48000 and w['receipt'].get('channels')==2,'worklet:terminal-frame-count')
  need(w['outputLength']==8192 and [x['channel'] for x in w['channels']]==[0,1] and all(x['length']==8192 and x['maxError']<=1e-6 for x in w['channels']),'worklet:actual-output')
  need(w['portClosed'] and w['nodesDisconnected'],'worklet:resource-release')
 invalid={x['name']:x['error'] for x in data['invalid']}
 for name,expected in [('unknown-processor','InvalidStateError'),('zero-input-output','NotSupportedError'),('invalid-fft','IndexSizeError'),('invalid-smoothing','IndexSizeError'),('invalid-channels','NotSupportedError')]:need(invalid.get(name)==expected,'invalid:'+name)
 return {'checks':checks,'issues':issues,'passed':not issues}

if __name__=='__main__':
 p=Path(sys.argv[1]);d=json.loads(p.read_text());r=verify(d)
 r['negativeControlsQualified']=r['passed']
 controls=[]
 for name,mutate in [('missing-completion',lambda a:a['data']['worklet'].__setitem__('renderCompleted',False)),('early-receipt',lambda a:a['data']['worklet']['receipt'].__setitem__('frames',128)),('wrong-output',lambda a:a['data']['worklet']['channels'][0].__setitem__('maxError',0.1)),('clamped-dc',lambda a:a['data']['analysers'][1].__setitem__('floatTail',[1.0]*16)),('silent-noise',lambda a:a['data']['analysers'][0].__setitem__('frequencyAllNegativeInfinity',False)),('fft-frequency',lambda a:a['data']['analysers'][3].__setitem__('peakBin',3)),('error-swallowed',lambda a:a['data']['invalid'][0].__setitem__('error',None))]:
  broken=copy.deepcopy(d)
  try:mutate(broken);controls.append({'name':name,'rejected':not verify(broken)['passed']})
  except (IndexError,KeyError,TypeError,AttributeError):controls.append({'name':name,'rejected':False,'reason':'missing actual operation receipt'})
 r.update(negativeControls=controls,runtimeVersion=d['runtimeVersion'],executableSHA256=d['executableSHA256'],label=d['label'],scope='Completed native OfflineAudio, float/byte analyser, real FFT, AudioWorklet output and invalid APIs; real hardware/audio permissions remain separate')
 if not all(c['rejected'] for c in controls):r['passed']=False;r['issues'].append('negative-control-insensitive')
 p.with_name(p.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(0 if r['passed'] else 2)
