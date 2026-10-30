import assert from 'node:assert/strict';
import fs from 'node:fs';
import {fileURLToPath} from 'node:url';

export function verify(data){
 const issues=[];
 if(data?.kind!=='webgpu-actual-compute-operations')return ['missing WebGPU operation evidence'];
 // A missing adapter is a legitimate unavailable signal, never an operation
 // PASS. This comparator is invoked only for the available native baseline.
 if(data.status!=='observed'||typeof data.observation!=='string'||!data.observation.startsWith('available:'))issues.push('no actual available adapter operation');
 if(data.compilationErrors!==0)issues.push('shader compilation failed or missing');
 if(!Array.isArray(data.values)||data.values.length!==16||data.values.some((x,i)=>x!==i*i+17))issues.push('compute readback disagrees with independent expected values');
 if(data.invalidBindingControl?.validationErrorObserved!==true)issues.push('actual invalid binding control missing');
 if(data.deviceDestroyed!==true)issues.push('native device teardown not proved');
 if(!Array.isArray(data.errors)||data.errors.length)issues.push('operation errors');
 return issues;
}

if(process.argv[1]===fileURLToPath(import.meta.url)){
 if(process.argv[2]==='--self-test'){
  const good={kind:'webgpu-actual-compute-operations',status:'observed',observation:'available:owned',compilationErrors:0,values:Array.from({length:16},(_,i)=>i*i+17),invalidBindingControl:{validationErrorObserved:true},deviceDestroyed:true,errors:[]};
  assert.deepEqual(verify(good),[]);
  const mutations=[x=>x.status='unavailable',x=>x.observation='adapter-null',x=>x.compilationErrors=1,x=>delete x.compilationErrors,x=>x.values[7]++,x=>x.values.pop(),x=>delete x.values,x=>x.invalidBindingControl.validationErrorObserved=false,x=>delete x.invalidBindingControl,x=>x.deviceDestroyed=false,x=>x.errors.push('error')];
  for(const mutate of mutations){const copy=structuredClone(good);mutate(copy);assert(verify(copy).length);}
  console.log(JSON.stringify({positiveControls:1,negativeControls:mutations.length,actualBrowser:false}));
 }else{
  const r=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));assert(r.headed===true&&r.mode==='unconfigured'&&r.documentEvidence?.loaded===true&&r.cleanupVerified===true);
  const issues=verify(r.data);console.log(JSON.stringify({status:issues.length?'failed':'verified-scoped-native-baseline',version:r.runtimeVersion,executableSHA256:r.executableSHA256,issues,productionWebGPUEnabled:false,finalCandidateQualified:false}));process.exitCode=issues.length?1:0;
 }
}
