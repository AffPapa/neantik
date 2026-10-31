// Synthetic/file controls are not browser qualification.
import assert from 'node:assert/strict';
import fs from 'node:fs';import vm from 'node:vm';
import {test} from 'node:test';import {PassThrough} from 'node:stream';
import {FontAccessPipe} from './font-access-pipe.mjs';
import {checkFontAccess,checkFontAccessABA} from './font-access-semantics.mjs';
import {fontAccessForeignSource,fontAccessTopSource} from './font-access-fixture.mjs';
const nonce='a'.repeat(32),origins=['http://127.0.0.1:12345','http://localhost:12346'];
function transport(){const input=new PassThrough(),output=new PassThrough(),pipe=new FontAccessPipe(input,output,origins,nonce),writes=[];input.on('data',data=>writes.push(JSON.parse(data.toString().slice(0,-1))));return {pipe,writes,reply:value=>output.write(JSON.stringify(value)+'\0')};}
async function bound(f){
 let promise=f.pipe.command('Target.createTarget',{url:'about:blank'});f.reply({id:1,result:{targetId:'own-page'}});await promise;
 promise=f.pipe.command('Target.attachToTarget',{targetId:'own-page',flatten:true});f.reply({id:2,result:{sessionId:'own-session'}});await promise;
 f.reply({method:'Runtime.executionContextCreated',sessionId:'own-session',params:{context:{id:11,uniqueId:'own-unique-id',origin:origins[0],auxData:{isDefault:true,frameId:'own-page'}}}});
 promise=f.pipe.command('Target.getTargetInfo',{targetId:'own-page'});f.reply({id:3,result:{targetInfo:{targetId:'own-page',type:'page',url:origins[0]+'/access?nonce='+nonce,browserContextId:'own-context'}}});await promise;
 promise=f.pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:11,returnByValue:true},'own-session');f.reply({id:4,result:{result:{value:nonce}}});await promise;
}
test('permission writes require exact nonce-bound target/context/descriptor/origin before send',async()=>{
 const f=transport();try{
  await assert.rejects(f.pipe.command('Browser.setPermission',{permission:{name:'local-fonts'},setting:'granted',origin:origins[0],embeddedOrigin:origins[0],browserContextId:'own-context'}));
  await bound(f);const params={permission:{name:'local-fonts'},setting:'denied',origin:origins[0],embeddedOrigin:origins[0],browserContextId:'own-context'};
  for(const mutate of [v=>delete v.origin,v=>delete v.embeddedOrigin,v=>delete v.browserContextId,v=>v.browserContextId='foreign',v=>v.origin=origins[1],v=>v.embeddedOrigin=origins[1],v=>v.setting='prompt',v=>v.permission.name='camera',v=>v.permission.allowWithoutGesture=true]){
   const bad=structuredClone(params);mutate(bad);const before=f.writes.length;await assert.rejects(f.pipe.command('Browser.setPermission',bad));assert.equal(f.writes.length,before);
  }
  const grant=f.pipe.scopedPermission('granted');f.reply({id:5,result:{}});await grant;assert.equal(f.writes.at(-1).params.browserContextId,'own-context');
  await assert.rejects(f.pipe.command('Browser.resetPermissions',{}));await assert.rejects(f.pipe.command('Browser.grantPermissions',{}));
 }finally{f.pipe.close();}
});
test('detach, destruction, context reset, foreign nonce navigation and EOF revoke permission authority',async()=>{
 for(const event of [
  {method:'Target.detachedFromTarget',params:{sessionId:'own-session'}},
  {method:'Target.targetDestroyed',params:{targetId:'own-page'}},
  {method:'Runtime.executionContextsCleared',sessionId:'own-session',params:{}},
  {method:'Target.targetInfoChanged',params:{targetInfo:{targetId:'own-page',type:'page',url:origins[0]+'/access?nonce='+'b'.repeat(32)}}},
  {method:'Page.frameNavigated',sessionId:'own-session',params:{frame:{url:'https://example.com/'}}},
  null,
 ]){const f=transport();try{await bound(f);if(event)f.reply(event);else f.pipe.close();const before=f.writes.length;await assert.rejects(f.pipe.scopedPermission('granted'));assert.equal(f.writes.length,before);}finally{f.pipe.close();}}
});
test('late TargetInfo/nonce/permission replies cannot restore revoked or rebound authority',async()=>{
 for(const method of ['Target.getTargetInfo','Runtime.evaluate','Browser.setPermission']){
  const f=transport();try{
   await bound(f);const params=method==='Target.getTargetInfo'?{targetId:'own-page'}:method==='Runtime.evaluate'?{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:11,returnByValue:true}:{permission:{name:'local-fonts'},setting:'denied',origin:origins[0],embeddedOrigin:origins[0],browserContextId:'own-context'};
   const request=f.pipe.command(method,params,method==='Runtime.evaluate'?'own-session':null),rejected=assert.rejects(request);
   f.reply({method:'Runtime.executionContextsCleared',sessionId:'own-session',params:{}});
   const result=method==='Target.getTargetInfo'?{targetInfo:{targetId:'own-page',type:'page',url:origins[0]+'/access?nonce='+nonce,browserContextId:'own-context'}}:method==='Runtime.evaluate'?{result:{value:nonce}}:{};
   f.reply({id:5,result});await rejected;const before=f.writes.length;await assert.rejects(f.pipe.scopedPermission('granted'));assert.equal(f.writes.length,before);
  }finally{f.pipe.close();}
 }
 const f=transport();try{
  await bound(f);const old=f.pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:11,returnByValue:true},'own-session'),rejected=assert.rejects(old);
  const rebind=f.pipe.command('Target.getTargetInfo',{targetId:'own-page'});f.reply({id:6,result:{targetInfo:{targetId:'own-page',type:'page',url:origins[0]+'/access?nonce='+nonce,browserContextId:'own-context'}}});await rebind;
  f.reply({id:5,result:{result:{value:nonce}}});await rejected;const before=f.writes.length;await assert.rejects(f.pipe.scopedPermission('granted'));assert.equal(f.writes.length,before);
 }finally{f.pipe.close();}
});
test('isolated, blank and child default contexts cannot confirm the top-page nonce',async()=>{
 const f=transport();try{
  await bound(f);
  for(const [id,auxData,origin]of [[12,{isDefault:false,frameId:'own-page'},origins[0]],[13,{isDefault:true,frameId:'child'},origins[0]],[14,{isDefault:true,frameId:'own-page'},'://']]){
   f.reply({method:'Runtime.executionContextCreated',sessionId:'own-session',params:{context:{id,uniqueId:'other-'+id,auxData,origin}}});const before=f.writes.length;
   await assert.rejects(f.pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:id,returnByValue:true},'own-session'));assert.equal(f.writes.length,before);
  }
 }finally{f.pipe.close();}
});
test('standalone B observation preserves A authority but never creates a B permission scope',async()=>{
 const f=transport();try{
  await bound(f);let request=f.pipe.command('Target.createTarget',{url:'about:blank'});f.reply({id:5,result:{targetId:'other-page'}});await request;
  request=f.pipe.command('Target.attachToTarget',{targetId:'other-page',flatten:true});f.reply({id:6,result:{sessionId:'other-session'}});await request;
  f.reply({method:'Target.targetInfoChanged',params:{targetInfo:{targetId:'other-page',type:'page',url:f.pipe.foreignPageURL}}});
  f.reply({method:'Runtime.executionContextCreated',sessionId:'other-session',params:{context:{id:22,uniqueId:'other-unique',origin:origins[1],auxData:{isDefault:true,frameId:'other-page'}}}});
  request=f.pipe.command('Target.getTargetInfo',{targetId:'other-page'});f.reply({id:7,result:{targetInfo:{targetId:'other-page',type:'page',url:f.pipe.foreignPageURL,browserContextId:'own-context'}}});await request;
  request=f.pipe.scopedPermission('denied');f.reply({id:8,result:{}});await request;assert.equal(f.writes.at(-1).params.origin,origins[0]);
  await assert.rejects(f.pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:22,returnByValue:true},'other-session'));
  request=f.pipe.command('Target.getTargetInfo',{targetId:'other-page'});const rejected=assert.rejects(request);f.reply({id:9,result:{targetInfo:{targetId:'other-page',type:'page',url:f.pipe.foreignPageURL,browserContextId:'wrong-context'}}});await rejected;
 }finally{f.pipe.close();}
});
test('own SFNT parser validates actual fixed files and refuses signature/name/directory corruption',()=>{
 const context=vm.createContext({Uint8Array,DataView,Map});vm.runInContext(fs.readFileSync(new URL('./font-access-sfnt.js',import.meta.url),'utf8'),context);
 const names=['NeAntikFontPolicyCanary','NeAntikFontPolicyFamilyCollision'];
 for(const [i,name]of ['owned-canary.ttf','owned-family-collision.ttf'].entries()){
  const bytes=new Uint8Array(fs.readFileSync(new URL('../../../runtime/font-policy-v1/witness/fonts/'+name,import.meta.url))),parsed=context.readOwnFontSFNT(bytes,names[i]);assert(parsed.tables.has('glyf'));
  assert.throws(()=>context.readOwnFontSFNT(bytes,'WrongKnownName'));
  for(const mutate of [v=>v.fill(0,0,4),v=>new DataView(v.buffer).setUint32(20,v.length+10),v=>new DataView(v.buffer).setUint32(36,12),v=>v.set(v.subarray(12,16),28)]){const changed=bytes.slice();mutate(changed);assert.throws(()=>context.readOwnFontSFNT(changed,names[i]));}
 }
});
function capture(policy=false){
 const summary=(index,revoke)=>({index,validSFNT:true,expectedPostscriptName:true,matchedOwnTables:index<2?5:0,drawingValid:true,removed:true,sameAsGranted:revoke?true:null}),indices=policy?[2]:[0,1,2];
 return {schemaVersion:1,nonce,ready:{secureContext:true,visible:true,initialPermission:'prompt',activeGesture:false,filteredNames:4},stages:['denied-initial','granted','denied-revoked'].map(phase=>({phase,permission:phase==='granted'?'granted':'denied',eventExpected:true,eventSeen:true,count:phase==='granted'?indices.length:0,selected:phase==='granted'?[!policy,!policy,true,false]:[false,false,false,false],blobs:phase==='denied-initial'?[]:indices.map(index=>summary(index,phase==='denied-revoked'))})),events:['denied','granted','denied'],foreign:{permission:'granted',policyAllowed:true,activeGesture:false,count:indices.length,queryError:null},topForeign:{topLevel:true,visible:true,permission:'prompt',policyAllowed:true,activeGesture:false,count:null,queryError:'SecurityError'},error:null,foreignRemoved:true};
}
test('permission/blob analyzer requires real operations, protected control, revoke and foreign denial',()=>{
 for(const mode of ['native','seeded-native','policy-a','policy-b','policy-a-repeat'])assert.equal(checkFontAccess(capture(mode.startsWith('policy')),mode).status,'passed');
 assert.equal(checkFontAccessABA(capture(true),capture(true)).status,'passed');
 const realEnumerationOrder=capture();for(const stage of realEnumerationOrder.stages)stage.blobs.sort((a,b)=>b.index-a.index);assert.equal(checkFontAccess(realEnumerationOrder,'native').status,'passed');
 for(const mutate of [v=>v.stages.pop(),v=>v.events.pop(),v=>v.error={kind:'Timeout'},v=>v.stages[0].count=1,v=>v.stages[1].selected[3]=true,v=>v.stages[1].blobs[0].matchedOwnTables=0,v=>v.stages[1].blobs[2].drawingValid=false,v=>v.stages[2].blobs[0].sameAsGranted=false,v=>v.topForeign.permission='granted',v=>v.foreign.policyAllowed=false,v=>v.topForeign.activeGesture=true,v=>v.topForeign.topLevel=false,v=>v.topForeign.visible=false,v=>v.stages[1].blobs[0].rawTable='forbidden',v=>v.foreignRemoved=false]){const value=capture();mutate(value);assert.throws(()=>checkFontAccess(value,'native'));}
 const initialDenied=capture();initialDenied.ready.initialPermission='denied';initialDenied.events.shift();initialDenied.stages[0].eventExpected=false;initialDenied.stages[0].eventSeen=false;assert.equal(checkFontAccess(initialDenied,'native').status,'passed');
 const leaked=capture(true);leaked.stages[1].selected[0]=true;assert.throws(()=>checkFontAccess(leaked,'policy-a'));
});
test('fixed page, SFNT and foreign operation sources parse without interpolated script termination',()=>{
 for(const name of ['font-access-page.js','font-access-sfnt.js'])new vm.Script(fs.readFileSync(new URL(name,import.meta.url),'utf8'));
 const source=fontAccessForeignSource({nonce,origin:origins[0]});new vm.Script(source);assert(!source.includes('</script>'));
 new vm.Script(fontAccessTopSource({nonce,origin:origins[0]}));
});
