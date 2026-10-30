import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import {fileURLToPath} from 'node:url';

const byteCount=1048576;
// Independent construction: repeat the 256-byte period, rather than the
// browser fixture's per-byte loop. This checks the stored data, not its label.
const period=Buffer.from(Array.from({length:256},(_,i)=>(i*7+19)%256));
const hash=crypto.createHash('sha256');
for(let i=0;i<byteCount/period.length;i++)hash.update(period);
const expectedSHA256=hash.digest('hex');
const finiteNonnegative=x=>Number.isFinite(x)&&x>=0;

export function verify(d){
 const issues=[];
 if(d?.kind!=='platform-state-and-memory-operations')return ['missing platform operation evidence'];
 if(!Array.isArray(d.errors)||d.errors.length)issues.push('native observation or operation error');
 if(d.connection?.status==='observed'){
  if(!Array.isArray(d.connection.samples)||d.connection.samples.length!==2||d.connection.samples.some(s=>!['slow-2g','2g','3g','4g'].includes(s.effectiveType)||!finiteNonnegative(s.rtt)||!finiteNonnegative(s.downlink)||typeof s.saveData!=='boolean'))issues.push('invalid native connection samples');
  if(!Number.isSafeInteger(d.connection.events)||d.connection.events<0)issues.push('invalid connection event count');
 }else if(d.connection?.status!=='unavailable')issues.push('connection missing or failed');
 if(d.battery?.status==='observed'){
  if(['sameObject','chargingBoolean','levelInRange','chargingTimeValid','dischargingTimeValid','listenerAPI'].some(k=>d.battery[k]!==true))issues.push('battery object or value invariant violated');
 }else if(d.battery?.status!=='unavailable')issues.push('battery missing or failed');
 if(d.heap?.status!=='observed'||d.heap.allocatedElements!==2048||d.heap.checksum!==13*(2048*2047/2)+3*2048)issues.push('bounded allocation readback mismatch');
 const h=d.heap?.nativeHeap;
 if(h?.status==='observed'){
  if(![h.used,h.total,h.limit].every(finiteNonnegative)||h.limit<=0||h.used>h.total||h.total>h.limit)issues.push('native heap bounds invalid');
 }else if(h?.status!=='unavailable')issues.push('heap observation missing or failed');
 if(d.deviceMemory?.status==='observed'){
  if(![2,4,8,16,32].includes(d.deviceMemory.value))issues.push('device memory outside current desktop Chromium buckets');
 }else if(d.deviceMemory?.status!=='unavailable')issues.push('device memory missing or failed');
 const s=d.storage;
 if(s?.status!=='observed'||s.strictCommitCompleted!==true||s.retrievedBytes!==byteCount||s.retrievedSHA256!==expectedSHA256||s.quotaCoversOwnBytes!==true||s.usageValid!==true||s.databaseDeleted!==true)issues.push('strict IDB commit/readback/estimate/cleanup not proved');
 if(!Array.isArray(d.permissions)||d.permissions.length!==2||['camera','microphone'].some(name=>d.permissions.filter(p=>p.name===name).length!==1)||d.permissions.some(p=>p.status==='observed'?!['prompt','granted','denied'].includes(p.state):p.status!=='unavailable'))issues.push('permission state evidence malformed');
 if(typeof d.speechDescriptor?.present!=='boolean'||d.speechDescriptor.nativeVoices!=='not_observed')issues.push('voice observation scope not explicit');
 return issues;
}

if(process.argv[1]===fileURLToPath(import.meta.url)){
 if(process.argv[2]==='--self-test'){
  const good={kind:'platform-state-and-memory-operations',errors:[],connection:{status:'observed',samples:[0,1].map(()=>({effectiveType:'4g',rtt:100,downlink:1.5,saveData:false})),events:0},battery:{status:'observed',sameObject:true,chargingBoolean:true,levelInRange:true,chargingTimeValid:true,dischargingTimeValid:true,listenerAPI:true},heap:{status:'observed',allocatedElements:2048,checksum:27255808,nativeHeap:{status:'observed',used:10,total:20,limit:30}},deviceMemory:{status:'observed',value:8},storage:{status:'observed',strictCommitCompleted:true,retrievedBytes:byteCount,retrievedSHA256:expectedSHA256,quotaCoversOwnBytes:true,usageValid:true,databaseDeleted:true},permissions:['camera','microphone'].map(name=>({name,status:'observed',state:'prompt'})),speechDescriptor:{present:true,nativeVoices:'not_observed'}};
  assert.deepEqual(verify(good),[]);
  const absent=structuredClone(good);
  for(const k of ['connection','battery','deviceMemory'])absent[k]={status:'unavailable'};
  absent.heap.nativeHeap={status:'unavailable'};absent.permissions=absent.permissions.map(p=>({name:p.name,status:'unavailable'}));
  assert.deepEqual(verify(absent),[]);
  const mutations=[x=>delete x.connection,x=>x.connection.samples[0].rtt=-1,x=>x.connection.samples.pop(),x=>x.connection.events=-1,x=>x.battery.status='error',x=>x.battery.sameObject=false,x=>x.battery.levelInRange=false,x=>x.heap.checksum++,x=>x.heap.nativeHeap.used=21,x=>x.deviceMemory.value=3,x=>x.storage.strictCommitCompleted=false,x=>x.storage.retrievedBytes--,x=>x.storage.retrievedSHA256='0'.repeat(64),x=>x.storage.quotaCoversOwnBytes=false,x=>x.storage.databaseDeleted=false,x=>x.permissions[0].state='unknown',x=>x.permissions[0].name='microphone',x=>x.permissions.pop(),x=>x.speechDescriptor.nativeVoices='observed',x=>x.errors.push('timeout')];
  for(const mutate of mutations){const copy=structuredClone(good);mutate(copy);assert(verify(copy).length);}
  console.log(JSON.stringify({positiveControls:2,negativeControls:mutations.length,actualBrowser:false}));
 }else{
  const r=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
  assert(r.headed===true&&r.documentEvidence?.loaded===true&&r.cleanupVerified===true&&r.browserClosure?.gracefulParentExit===true&&r.fixtureSourceArchive?.manifestSHA256===r.fixtureProvenance?.manifestSHA256);
  const issues=verify(r.data);
  console.log(JSON.stringify({status:issues.length?'failed':'verified-scoped-platform-operations',issues,version:r.runtimeVersion,executableSHA256:r.executableSHA256,voiceBehaviorVerified:false,captureVerified:false,powerChangeEventsVerified:false,networkChangeEventsVerified:false,finalCandidateQualified:false}));process.exitCode=issues.length?1:0;
 }
}
