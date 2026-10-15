// Offline parser/envelope controls only. Synthetic rows never certify a browser.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {parseAcknowledgements,validateProbeEnvelope,modes} from '../run-font-policy.mjs';
const nonce='a'.repeat(32),hashes={canarySHA256:'b'.repeat(64),ahemSHA256:'c'.repeat(64)};
function envelope() {
 const measurements=[];
 const add=(family,fallback,style,text)=>measurements.push({family,fallback,style,text,widths:[1,1,1],inkPixels:1,maskSHA256:'d'.repeat(64),domWidths:[1,1,1]});
 for(const family of ['NeAntikFontPolicyCanary','Helvetica',`NeAntikMissing_${nonce}`])for(const fallback of ['monospace','serif'])for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B'])add(family,fallback,style,text);
 for(const family of ['QALocalUnique','QARemoteCanary','QARemoteAhem'])for(const fallback of ['monospace','serif'])add(family,fallback,'normal 400','ABABA');
 const page={kind:'own-font-policy-realm',nonce,realm:'page',available:{canvas:true,fontFace:true,fontSet:true,dom:true},local:[{kind:'known-own-unique',loaded:true,timedOut:false},{kind:'invented-missing',loaded:false,timedOut:false}],resources:[{family:'QARemoteCanary',loaded:true,timedOut:false,sha256:hashes.canarySHA256,bytes:1124},{family:'QARemoteAhem',loaded:true,timedOut:false,sha256:hashes.ahemSHA256,bytes:1000}],measurements,errors:[],ownFontFacesRemoved:true};
 const worker=structuredClone(page);worker.realm='worker';worker.available.dom=false;worker.measurements.forEach(row=>row.domWidths=null);
 return {schemaVersion:1,nonce,error:null,workerTerminationRequested:true,realms:[page,worker]};
}
test('complete ACK syntax accepted, malformed/stale/partial/duplicate ACK refused',()=>{
 const line=(pid,role)=>`NEANTIK_FONT_QA_V1 nonce=${nonce} pid=${pid} role=${role} complete=1 unique=1 family=1\n`;
 const valid=line(123,'browser')+line(124,'renderer');assert.equal(parseAcknowledgements(valid,nonce).length,2);
 for(const text of ['',line(0,'browser'),line(2147483648,'browser'),valid.replace('unique=1','unique=0'),valid.replace(nonce,'b'.repeat(32)),valid+line(124,'renderer'),valid+'NEANTIK_FONT_QA_V1 incomplete\n'])assert.throws(()=>parseAcknowledgements(text,nonce));
});
test('complete synthetic envelope is accepted only as structure, not behavior',()=>{
 assert.equal(validateProbeEnvelope(envelope(),nonce,hashes),true);
 assert.deepEqual(modes,['native','seeded-native','policy-a','policy-b','policy-a-repeat']);
});
test('worker/page errors, missing/duplicate realms, unavailable API and incomplete operations refuse',()=>{
 const mutations=[
  v=>v.error='OwnWorkerTimeout',v=>v.realms.pop(),v=>v.realms[1]=structuredClone(v.realms[0]),
  v=>v.realms[1].errors.push('WorkerError'),v=>v.realms[0].available.canvas=false,
  v=>v.realms[0].nonce='b'.repeat(32),v=>v.realms[1].ownFontFacesRemoved=false,
  v=>v.realms[0].measurements.pop(),v=>v.realms[0].measurements[1]=structuredClone(v.realms[0].measurements[0]),
  v=>v.realms[0].measurements[0].widths[1]=null,v=>v.realms[1].measurements[0].domWidths=[1,1,1],
  v=>v.realms[0].resources[0].loaded=false,v=>v.realms[1].resources[1].timedOut=true,
  v=>v.realms[1].resources[0].sha256='e'.repeat(64),v=>v.realms[0].local[0].timedOut=true,
 ];
 for(const mutate of mutations){const value=envelope();mutate(value);assert.throws(()=>validateProbeEnvelope(value,nonce,hashes));}
});
