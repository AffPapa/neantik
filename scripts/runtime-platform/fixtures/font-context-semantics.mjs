import assert from 'node:assert/strict';
import {fontContextNames} from './font-context-fixture.mjs';
import {checkFontSession,checkFontABA} from './font-policy-semantics.mjs';
const windows=new Set(['page',...fontContextNames.slice(5)]),workers=['DedicatedWorker','SharedWorker','ServiceWorker'];
const targetType={page:'page',DedicatedWorker:'worker',SharedWorker:'shared_worker',ServiceWorker:'service_worker',AudioWorklet:'worklet','same-origin iframe':'page','about:blank iframe':'page','srcdoc iframe':'page','cross-origin OOPIF':'iframe'};
const hash=value=>assert(/^[a-f0-9]{64}$/.test(value));
const drawEqual=(a,b)=>Math.abs(a.widths[0]-b.widths[0])<=0.08&&a.inkPixels===b.inkPixels&&a.maskSHA256===b.maskSHA256;
function nativeGenericGap(page,worker,nonce) {
  const rows=new Map(page.measurements.map(row=>[JSON.stringify([row.family,row.fallback,row.style,row.text]),row]));let differences=0;
  for(const row of worker.measurements) {
    const reference=rows.get(JSON.stringify([row.family,row.fallback,row.style,row.text]));
    for(const field of [null,'matched']) {
      const a=field?row[field]:row,b=field?reference[field]:reference;
      if(drawEqual(a,b))continue;
      assert.equal(row.family,`NeAntikMissing_${nonce}`,'Unexpected native font difference');assert.equal(row.fallback,'monospace','Unexpected native generic difference');
      const serif=worker.measurements.find(x=>x.family===row.family&&x.fallback==='serif'&&x.style===row.style&&x.text===row.text);
      assert(drawEqual(a,field?serif[field]:serif),'Native empty-map fallback differs from observed serif');differences++;
    }
  }
  assert.equal(differences,12,'Native upstream negative control changed');
  return {status:'observed-upstream-native-gap',differingRowVariants:differences,checks:0,scope:'sensitive negative control; no native cross-realm coherence PASS'};
}
function drawable(value,mode) {
  assert.equal(value?.schemaVersion,1);assert(/^[a-f0-9]{32}$/.test(value.nonce));assert.equal(value.error,null);
  assert.deepEqual(value.results.map(row=>row.name),fontContextNames);
  const map=new Map();
  for(const row of value.results) {
    assert.equal(row.created,true);assert.equal(row.error,null);assert(/^[a-f0-9]{32}$/.test(row.contextNonce));assert.equal(row.value.contextNonce,row.contextNonce);
    assert.equal(row.lifecycleCreation?.confirmed,true);assert.equal(row.lifecycleCreation.uniqueContext,true);assert.equal(row.lifecycleCreation.targetType,targetType[row.name],'Wrong actual context type');map.set(row.name,row.value);
    if(row.name==='AudioWorklet'){
      assert.deepEqual(row.value.available,{fontFace:false,fontSet:false,canvas:false,dom:false},'Unexpected worklet font API exposure');
      assert.deepEqual(row.value.processing,{frames:128,allQuarter:true,sampleRate:44100},'Worklet processing not completed');continue;
    }
    const font=row.value.font;assert.equal(font.kind,'own-font-policy-realm');assert.equal(font.nonce,value.nonce);
    assert.equal(font.realm,windows.has(row.name)?'page':'worker');assert.deepEqual(font.errors,[]);assert.equal(font.ownFontFacesRemoved,true);assert.equal(font.fontSetReadyAfterLoads,true);
    assert.deepEqual(font.available,{canvas:true,fontFace:true,fontSet:true,dom:windows.has(row.name)});
    assert.equal(font.resources.length,2);
    for(const family of ['QARemoteCanary','QARemoteAhem']){
      const loaded=font.resources.filter(x=>x.family===family);assert.equal(loaded.length,1);assert.equal(loaded[0].loaded,true);assert.equal(loaded[0].timedOut,false);hash(loaded[0].sha256);
    }
    for(const face of font.local)assert.equal(face.timedOut,false);
  }
  assert.equal(new Set(value.results.map(x=>x.contextNonce)).size,9,'Duplicate realm nonce');
  const pairs=[],comparisons=[];
  for(const name of workers){
    const realms=[map.get('page').font,map.get(name).font];pairs.push(realms);
    if(mode==='native'&&name!=='DedicatedWorker'){
      // Preserve the strict check as an actual failing negative. The source and
      // first capture prove native standalone workers have empty generic maps.
      assert.throws(()=>checkFontSession({nonce:value.nonce,realms},mode),error=>error.name==='AssertionError'&&error.message==='Page and DedicatedWorker font drawing disagree');
      comparisons.push(nativeGenericGap(...realms,value.nonce));
    }else comparisons.push(checkFontSession({nonce:value.nonce,realms},mode));
  }
  for(const name of fontContextNames.slice(5))pairs.push([map.get(name).font,map.get('DedicatedWorker').font]);
  for(const realms of pairs.slice(workers.length))comparisons.push(checkFontSession({nonce:value.nonce,realms},mode));
  return {map,pairs,comparisons};
}
export function checkFontContextCapture(value,mode,resourceHashes) {
  const {map,comparisons}=drawable(value,mode);
  for(const [name,row] of map)if(row.font)for(const resource of row.font.resources)assert.equal(resource.sha256,resource.family==='QARemoteCanary'?resourceHashes.canarySHA256:resourceHashes.ahemSHA256,'Changed font bytes in realm');
  const genericNames=['standard','serif','monospace','sans-serif','cursive','fantasy','math'];let genericCrossRealmRows=0;const nativeGenericDifferences=[];
  const pageRows=new Map(map.get('page').generics.map(row=>[JSON.stringify([row.generic,row.style,row.text]),row]));
  for(const [name,value] of map)if(value.font){
    const expected=new Set();for(const generic of genericNames)for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B'])expected.add(JSON.stringify([generic,style,text]));
    assert.equal(value.generics.length,42);let differences=0;
    for(const row of value.generics){
      const key=JSON.stringify([row.generic,row.style,row.text]);assert(expected.delete(key),'Missing/duplicate generic operation');
      const family=row.generic==='standard'?`"NeAntikMissing_${value.font.nonce}"`:row.generic;
      const familyForms=row.generic==='standard'?[family,family.slice(1,-1)]:[family];
      const prefixes=row.style==='normal 700'?['bold ','700 ']:row.style==='italic 400'?['italic ','italic 400 ']:['','400 '];
      assert(prefixes.some(prefix=>familyForms.some(font=>row.appliedFont===`${prefix}20px ${font}`)),`Generic font assignment rejected: ${row.appliedFont}`);
      assert.deepEqual(row.typography,{fontKerning:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'});
      assert(row.widths.length===3&&row.widths.every(x=>Number.isFinite(x)&&x>0&&Math.abs(x-row.widths[0])<=0.08));hash(row.maskSHA256);assert(Number.isSafeInteger(row.inkPixels)&&row.inkPixels>0&&row.inkPixels<=17920);
      if(name!=='page'){
        if(mode==='native'){if(['SharedWorker','ServiceWorker'].includes(name)){if(!drawEqual(row,pageRows.get(key)))differences++;}else assert(drawEqual(row,pageRows.get(key)),'Unexpected native frame/dedicated generic difference');}
        else{assert(drawEqual(row,pageRows.get(key)),'Configured generic font differs across realms');genericCrossRealmRows++;}
      }
    }
    assert.equal(expected.size,0);if(mode==='native')nativeGenericDifferences.push({name,differingRows:differences});
  }
  return {status:mode==='native'?'observed-upstream-native-gap':'passed',contexts:9,drawableContexts:8,pairComparisons:comparisons.length,pairAssertions:comparisons.reduce((sum,x)=>sum+x.checks,0),nativeGapNegatives:comparisons.filter(x=>x.status==='observed-upstream-native-gap').length,genericRowsPerContext:42,genericCrossRealmRows,nativeGenericDifferences,scope:'font-only operations; native upstream generic gap retained as negative; AudioWorklet records API absence plus processing'};
}
export function checkFontContextLifecycle(value) {
  assert.deepEqual(value.recorderErrors,[]);assert.deepEqual(value.receipts.map(x=>x.name),fontContextNames);
  for(const row of value.receipts){
    assert.equal(row.confirmed,true);assert.equal(row.uniqueContext,true);assert.equal(row.targetType,targetType[row.name],'Wrong actual context type');assert.equal(row.terminated,true,'Context still live');
    if(row.name==='ServiceWorker'){assert.equal(row.versionBound,true);assert.equal(row.mechanism,'observed-service-worker-stopped');}
    else assert(['context-destroyed','session-contexts-cleared','target-destroyed',...(row.name==='SharedWorker'?['shared-worker-host-destroyed-notification']:[])].includes(row.mechanism),'Unproven context destruction');
  }
  assert.equal(new Set(value.contextIdentitySHA256).size,9);assert.equal(value.contextIdentitySHA256.length,9);value.contextIdentitySHA256.forEach(hash);
  assert.equal(value.oopif?.targetType,'iframe');assert.equal(value.oopif.separateTarget,true);assert.equal(value.oopif.frameLinked,true);assert.equal(value.oopif.foreignOrigin,true);
  assert.deepEqual(value.frameContexts.map(row=>row.name),fontContextNames.slice(5));
  for(const row of value.frameContexts){assert.equal(row.childFrameLinked,true);assert.equal(row.defaultContext,true);assert.equal(row.expectedURL,true);}
  return {status:'passed',contexts:9,scope:'independent realm/target destruction; no physical shared backing-thread destruction claim'};
}
export function checkFontContextABA(first,last,resourceHashes) {
  checkFontContextCapture(first,'policy-a',resourceHashes);checkFontContextCapture(last,'policy-a-repeat',resourceHashes);
  assert.equal(first.nonce,last.nonce);let checks=0;
  const a=drawable(first,'policy-a'),b=drawable(last,'policy-a-repeat');
  for(let i=0;i<a.pairs.length;i++)checks+=checkFontABA({nonce:first.nonce,realms:a.pairs[i]},{nonce:last.nonce,realms:b.pairs[i]}).checks;
  for(let i=0;i<9;i++)assert.notEqual(first.results[i].contextNonce,last.results[i].contextNonce,'Reused old capture instead of a new realm');
  for(const name of fontContextNames)if(name!=='AudioWorklet'){
    const before=a.map.get(name).generics,after=b.map.get(name).generics;assert.equal(before.length,after.length);
    for(let i=0;i<before.length;i++){assert.deepEqual([before[i].generic,before[i].style,before[i].text],[after[i].generic,after[i].style,after[i].text]);assert(drawEqual(before[i],after[i]),'A generic drawing changed after B');checks++;}
  }
  return {status:'passed',pairAssertions:checks,contexts:9,scope:'same owned A root after B with new actual realms and stable font operations'};
}

// Remote frames are intentionally absent from the parent renderer's local tree.
export function checkFontOOPIFBinding(tree,cross,remoteTree,crossValue,origin,nonce) {
  assert(cross&&cross.target.type==='iframe'&&cross.context.auxData?.isDefault===true,'Missing actual OOPIF context');
  const frame=remoteTree?.frameTree?.frame,parent=tree?.frameTree?.frame;
  assert(frame&&parent&&frame.id===cross.target.targetId&&cross.context.auxData.frameId===frame.id&&frame.parentId===parent.id&&cross.target.parentFrameId===parent.id,'OOPIF not linked to actual child frame');
  const url=new URL(frame.url);assert.equal(url.origin,origin);assert.equal(url.pathname,'/frame');assert.equal(url.searchParams.get('nonce'),nonce);assert.equal(url.searchParams.get('contextNonce'),crossValue.contextNonce);
  assert.equal(cross.target.url,frame.url);assert.notEqual(frame.id,parent.id);
  return frame;
}

export function checkFontWorkerBinding(name,record,pageURL,nonce,requests,contextNonce,pageTargetId,expectedModuleSHA256) {
  assert.equal(record?.nonce,contextNonce,'Worker context nonce mismatch');
  const page=new URL(pageURL),url=new URL(record.target.url);
  assert.equal(url.origin,page.origin);assert.equal(url.searchParams.get('nonce'),nonce);
  const expected={DedicatedWorker:['worker','/dedicated.js'],SharedWorker:['shared_worker','/shared.js'],ServiceWorker:['service_worker','/service.js'],AudioWorklet:['worklet','/own']}[name];
  assert(expected,'Unknown worker role');assert.equal(record.target.type,expected[0]);assert.equal(url.pathname,expected[1]);
  if(name==='AudioWorklet'){
    assert.equal(url.href,page.href,'Worklet creator document changed');assert.equal(record.target.parentId,pageTargetId,'Worklet parent target changed');
    assert(requests.some(row=>row.site===0&&row.path==='/worklet.js'&&row.method==='GET'&&row.served===true&&row.servedModuleSHA256===expectedModuleSHA256&&row.contextNonce===contextNonce&&row.custody?.sameProcessGroup===true&&row.custody?.runtimePathBound===true),'Missing own worklet module request');
  }
  return {name,targetType:expected[0],urlKind:name==='AudioWorklet'?'creator-document':'worker-script',ownModuleBound:true};
}
