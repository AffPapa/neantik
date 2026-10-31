// Deliberately synthetic analyzer controls, never browser evidence.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fontContextNames} from './font-context-fixture.mjs';
import {checkFontContextCapture,checkFontContextLifecycle,checkFontContextABA,checkFontOOPIFBinding,checkFontWorkerBinding} from './font-context-semantics.mjs';
const nonce='a'.repeat(32),hashes={canarySHA256:'b'.repeat(64),ahemSHA256:'c'.repeat(64)};
const windows=new Set(['page',...fontContextNames.slice(5)]);
const types=['page','worker','shared_worker','service_worker','worklet','page','page','page','iframe'];
function font(window,policy) {
 const measurements=[];
 const add=(family,fallback,style,text)=>{
  const absent=family.startsWith('NeAntikMissing_')||(policy&&['NeAntikFontPolicyCanary','QALocalUnique'].includes(family));
  const width=family==='QARemoteAhem'?100:absent?(fallback==='serif'?61:60):family==='Helvetica'&&policy?55:73;
  const mask=(family==='QARemoteAhem'?'e':absent?(fallback==='serif'?'f':'a'):family==='Helvetica'&&policy?'b':'c').repeat(64);
  const capture={widths:[width,width,width],domWidths:window?[width,width,width]:null,inkPixels:width,maskSHA256:mask,wordBoundary:text.includes(' ')?{canvasPieces:Array(7).fill(width/7),domPieces:window?Array(7).fill(width/7):null}:null};
  measurements.push({family,fallback,style,text,...capture,matched:{...structuredClone(capture),typography:{fontKerning:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'},...(window?{domTypography:{fontKerning:'none',fontVariantLigatures:'none',textRendering:'optimizespeed',letterSpacing:'normal',wordSpacing:'0px'}}:{})}});
 };
 for(const family of ['NeAntikFontPolicyCanary','Helvetica',`NeAntikMissing_${nonce}`])for(const fallback of ['monospace','serif'])for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B'])add(family,fallback,style,text);
 for(const family of ['QALocalUnique','QARemoteCanary','QARemoteAhem'])for(const fallback of ['monospace','serif'])add(family,fallback,'normal 400','ABABA');
 return {kind:'own-font-policy-realm',nonce,realm:window?'page':'worker',available:{canvas:true,fontFace:true,fontSet:true,dom:window},local:[{kind:'known-own-unique',loaded:!policy,error:policy?'NetworkError':null,timedOut:false},{kind:'invented-missing',loaded:false,error:'NetworkError',timedOut:false}],resources:[{family:'QARemoteCanary',loaded:true,timedOut:false,sha256:hashes.canarySHA256},{family:'QARemoteAhem',loaded:true,timedOut:false,sha256:hashes.ahemSHA256}],errors:[],ownFontFacesRemoved:true,fontSetReadyAfterLoads:true,measurements};
}
function fixture(policy=true,generation=0) {
 return {schemaVersion:1,nonce,error:null,results:fontContextNames.map((name,i)=>{
  const contextNonce=(i+1+generation*16).toString(16).padStart(32,'0');
  let drawing=null,generics=[];
  if(name!=='AudioWorklet'){
   drawing=font(windows.has(name),policy);
   if(!policy&&['SharedWorker','ServiceWorker'].includes(name))for(const row of drawing.measurements)if(row.family.startsWith('NeAntikMissing_')&&row.fallback==='monospace'){
    const serif=drawing.measurements.find(x=>x.family===row.family&&x.fallback==='serif'&&x.style===row.style&&x.text===row.text);
    for(const field of ['widths','inkPixels','maskSHA256','matched'])row[field]=structuredClone(serif[field]);
   }
   for(const [index,generic] of ['standard','serif','monospace','sans-serif','cursive','fantasy','math'].entries())for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B']){
    const width=!policy&&['SharedWorker','ServiceWorker'].includes(name)?70:70+index;
    generics.push({generic,style,text,appliedFont:(style==='normal 700'?'bold ':style==='italic 400'?'italic ':'')+'20px '+(generic==='standard'?`"NeAntikMissing_${nonce}"`:generic),typography:{fontKerning:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'},widths:[width,width,width],inkPixels:width,maskSHA256:'a'.repeat(64)});
   }
  }
  return {name,contextNonce,created:true,error:null,lifecycleCreation:{confirmed:true,uniqueContext:true,targetType:types[i]},value:{contextNonce,...(name==='AudioWorklet'?{available:{fontFace:false,fontSet:false,canvas:false,dom:false},processing:{frames:128,allQuarter:true,sampleRate:44100}}:{font:drawing,generics})}};
 })};
}
function lifecycle(){return {recorderErrors:[],receipts:fontContextNames.map((name,i)=>({name,confirmed:true,uniqueContext:true,targetType:types[i],terminated:true,mechanism:name==='ServiceWorker'?'observed-service-worker-stopped':'target-destroyed',versionBound:name==='ServiceWorker'?true:null})),contextIdentitySHA256:fontContextNames.map((_,i)=>String(i+1).repeat(64)),oopif:{targetType:'iframe',separateTarget:true,frameLinked:true,foreignOrigin:true},frameContexts:fontContextNames.slice(5).map(name=>({name,childFrameLinked:true,defaultContext:true,expectedURL:true}))};}
test('complete native/configured font captures cover eight drawable realms and worklet absence',()=>{
 for(const mode of ['native','policy-a','policy-b','policy-a-repeat']){const v=fixture(mode!=='native');const result=checkFontContextCapture(v,mode,hashes);assert.equal(result.contexts,9);assert.equal(result.drawableContexts,8);assert.equal(result.pairComparisons,7);assert.equal(result.nativeGapNegatives,mode==='native'?2:0);assert.equal(result.status,mode==='native'?'observed-upstream-native-gap':'passed');}
 assert.equal(checkFontContextABA(fixture(true,0),fixture(true,1),hashes).status,'passed');
});
test('missing/duplicate/errored realms, wrong scope, changed bytes and worklet failures refuse',()=>{
 for(const mutate of [
  v=>v.results.pop(),v=>v.results[4]=structuredClone(v.results[3]),v=>v.results[2].error={kind:'Error'},
  v=>v.results[1].created=false,v=>v.results[8].lifecycleCreation.confirmed=false,
  v=>v.results[2].value.font.realm='page',v=>v.results[2].value.font.fontSetReadyAfterLoads=false,
  v=>v.results[7].value.font.errors.push({kind:'Timeout'}),v=>v.results[7].value.font.resources[0].sha256='f'.repeat(64),
  v=>v.results[4].value.processing.allQuarter=false,v=>v.results[4].value.available.fontFace=true,
  v=>v.results[3].contextNonce=v.results[0].contextNonce,v=>v.results[3].value.font.measurements.pop(),
  v=>v.results[2].lifecycleCreation.targetType='worker',v=>v.results[1].lifecycleCreation.targetType='shared_worker',
  v=>v.results[1].value.generics[0].appliedFont='10px sans-serif',v=>v.results[0].value.generics[0].typography.fontKerning='auto',
  v=>v.results[1].value.generics.pop(),v=>v.results[6].value.generics[0].widths[1]+=1,
  v=>v.results[3].value.generics[0].maskSHA256='b'.repeat(64),
 ]){const v=fixture();mutate(v);assert.throws(()=>checkFontContextCapture(v,'policy-a',hashes));}
 const same=fixture();assert.throws(()=>checkFontContextABA(same,structuredClone(same),hashes),/Reused old capture/);
 const changed=fixture(true,1);changed.results[3].value.font.measurements[0].matched.widths[1]+=1;assert.throws(()=>checkFontContextABA(fixture(),changed,hashes));
 for(const index of [1,5,6,7,8]){const v=fixture(false);v.results[index].value.generics[0].maskSHA256='b'.repeat(64);assert.throws(()=>checkFontContextCapture(v,'native',hashes),/Unexpected native/);}
 const canonical=fixture();for(const result of canonical.results)for(const row of result.value.generics??[])row.appliedFont=row.appliedFont.replace(/^bold /,'700 ').replaceAll('\"','');assert.equal(checkFontContextCapture(canonical,'policy-a',hashes).status,'passed');
 const missingGap=fixture(false);missingGap.results[2].value.font=font(false,false);assert.throws(()=>checkFontContextCapture(missingGap,'native',hashes));
});
test('real lifecycle shape needs unique creation and independent destruction, not cleanup requests',()=>{
 assert.equal(checkFontContextLifecycle(lifecycle()).status,'passed');
 for(const mutate of [
  v=>v.receipts.pop(),v=>v.receipts[1].terminated=false,v=>v.receipts[3].mechanism='unregister',
  v=>v.receipts[3].versionBound=false,v=>v.contextIdentitySHA256[1]=v.contextIdentitySHA256[0],
  v=>v.oopif.targetType='page',v=>v.oopif.frameLinked=false,v=>v.oopif.foreignOrigin=false,
  v=>v.receipts[4].mechanism='disconnect-called',v=>v.recorderErrors.push('attach'),
  v=>v.receipts[2].targetType='worker',v=>v.frameContexts[1].childFrameLinked=false,v=>v.frameContexts[2].expectedURL=false,
 ]){const v=lifecycle();mutate(v);assert.throws(()=>checkFontContextLifecycle(v));}
 const live=lifecycle();live.receipts.forEach(row=>{row.terminated=false;row.mechanism='not-observed';});assert.throws(()=>checkFontContextLifecycle(live),/Context still live/);
});

test('remote OOPIF uses its own tree and independent parent/context/target linkage',()=>{
 const url='http://localhost:12346/frame?nonce='+nonce+'&contextNonce='+nonce;
 const fixture=()=>({tree:{frameTree:{frame:{id:'top'},childFrames:[]}},cross:{target:{type:'iframe',targetId:'remote',parentFrameId:'top',url},context:{auxData:{isDefault:true,frameId:'remote'}}},remote:{frameTree:{frame:{id:'remote',parentId:'top',url}}},value:{contextNonce:nonce}});
 const check=v=>checkFontOOPIFBinding(v.tree,v.cross,v.remote,v.value,'http://localhost:12346',nonce);
 assert.equal(check(fixture()).id,'remote');
 for(const mutate of [v=>v.cross.target.type='page',v=>v.cross.target.parentFrameId='other',v=>v.cross.context.auxData.frameId='other',v=>v.remote.frameTree.frame.parentId='other',v=>v.remote.frameTree.frame.url=url.replace('localhost','example.com'),v=>v.value.contextNonce='b'.repeat(32),v=>v.cross.context.auxData.isDefault=false]){const v=fixture();mutate(v);assert.throws(()=>check(v));}
});

test('worklet target binds creator document and actual own module, not a fictional module target URL',()=>{
 const page='http://127.0.0.1:12345/own?nonce='+nonce,contextNonce='d'.repeat(32);
 const fixture=()=>({record:{nonce:contextNonce,target:{type:'worklet',url:page,parentId:'own-page'}},requests:[{site:0,path:'/worklet.js',method:'GET',served:true,servedModuleSHA256:'e'.repeat(64),contextNonce,custody:{sameProcessGroup:true,runtimePathBound:true}}]});
 const check=v=>checkFontWorkerBinding('AudioWorklet',v.record,page,nonce,v.requests,contextNonce,'own-page','e'.repeat(64));
 assert.equal(check(fixture()).urlKind,'creator-document');
 for(const mutate of [v=>v.record.target.url=page.replace('/own','/worklet.js'),v=>v.record.target.type='worker',v=>v.requests=[],v=>v.requests[0].contextNonce='f'.repeat(32),v=>v.requests[0].custody.runtimePathBound=false,v=>v.record.nonce=nonce,v=>v.record.target.parentId='foreign',v=>v.requests[0].servedModuleSHA256='f'.repeat(64),v=>v.requests[0].served=false]){const v=fixture();mutate(v);assert.throws(()=>check(v));}
});
