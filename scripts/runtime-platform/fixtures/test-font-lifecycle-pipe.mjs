// Pure transport controls. Synthetic messages never certify actual contexts.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {PassThrough} from 'node:stream';
import {FontLifecyclePipe,lifecycleSocketAdapter} from './font-lifecycle-pipe.mjs';
const origins=['http://127.0.0.1:12345','http://localhost:12346'];
function fixture(){const input=new PassThrough(),output=new PassThrough(),pipe=new FontLifecyclePipe(input,output,origins);return {pipe,input,output,reply:value=>output.write(JSON.stringify(value)+'\0')};}
test('owned targets/sessions and fixed nonce observation only',async()=>{
 const f=fixture();try {
  const create=f.pipe.command('Target.createTarget',{url:'about:blank'});f.reply({id:1,result:{targetId:'own-page'}});await create;
  const attach=f.pipe.command('Target.attachToTarget',{targetId:'own-page',flatten:true});f.reply({id:2,result:{sessionId:'own-session'}});await attach;
  f.reply({method:'Runtime.executionContextCreated',sessionId:'own-session',params:{context:{id:11}}});
  const read=f.pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:11,returnByValue:true},'own-session');f.reply({id:3,result:{result:{value:'own-nonce'}}});assert.equal((await read).result.value,'own-nonce');
  for(const [m,p,s] of [
   ['Runtime.evaluate',{expression:'document.cookie',contextId:11,returnByValue:true},'own-session'],
   ['Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:12,returnByValue:true},'own-session'],
   ['Page.navigate',{url:'https://example.com'},'own-session'],['Runtime.enable',{},'unknown-session'],
   ['ServiceWorker.stopWorker',{versionId:'unknown-version'},'own-session'],
   ['Target.attachToTarget',{targetId:'unrelated-page',flatten:true},null],['Target.createTarget',{url:origins[0]+'/'},null],
   ['Runtime.callFunctionOn',{},'own-session'],['Browser.grantPermissions',{},null],
  ])assert.throws(()=>f.pipe.command(m,p,s));
  f.reply({method:'Runtime.executionContextDestroyed',sessionId:'own-session',params:{executionContextId:11}});
  assert.throws(()=>f.pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:11,returnByValue:true},'own-session'));
 }finally{f.pipe.close();}
});
test('adapter preserves lifecycle events and detaches listeners',()=>{
 const f=fixture(),adapter=lifecycleSocketAdapter(f.pipe),seen=[];const listener=e=>seen.push(JSON.parse(e.data));
 adapter.addEventListener('message',listener);f.reply({method:'Target.targetCreated',params:{targetInfo:{targetId:'own-worker',url:origins[0]+'/dedicated.js'}}});assert.equal(seen.length,1);assert(f.pipe.targets.has('own-worker'));
 adapter.removeEventListener('message',listener);f.reply({method:'Target.targetDestroyed',params:{targetId:'own-worker'}});assert.equal(seen.length,1);f.pipe.close();
});
test('malformed, unsolicited and oversized responses close the pipe',async()=>{
 for(const bytes of ['{bad\0',JSON.stringify({id:999,result:{}})+'\0','x'.repeat(262145)]){
  const f=fixture(),pending=f.pipe.command('Browser.getVersion');f.output.write(bytes);await assert.rejects(pending);assert.equal(f.pipe.closed,true);
 }
 const f=fixture(),create=f.pipe.command('Target.createTarget',{url:'about:blank'});f.reply({id:1,result:{}});await assert.rejects(create);assert.equal(f.pipe.closed,true);
});
test('foreign navigation, detach and destruction revoke observation custody',async()=>{
 for(const event of [
  {method:'Target.targetInfoChanged',params:{targetInfo:{targetId:'own-page',url:'https://example.com/'}}},
  {method:'Target.detachedFromTarget',params:{sessionId:'own-session'}},
  {method:'Target.targetDestroyed',params:{targetId:'own-page'}},
 ]) {
  const f=fixture();try {
   const create=f.pipe.command('Target.createTarget',{url:'about:blank'});f.reply({id:1,result:{targetId:'own-page'}});await create;
   const attach=f.pipe.command('Target.attachToTarget',{targetId:'own-page',flatten:true});f.reply({id:2,result:{sessionId:'own-session'}});await attach;
   f.reply({method:'Runtime.executionContextCreated',sessionId:'own-session',params:{context:{id:11}}});f.reply(event);
   f.reply({method:'Runtime.executionContextCreated',sessionId:'own-session',params:{context:{id:12}}});
   for(const contextId of [11,12])assert.throws(()=>f.pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId,returnByValue:true},'own-session'));
  }finally{f.pipe.close();}
 }
});

test('only owned OOPIF gets read-only frame inspection; worker and foreign target refuse',async()=>{
 const f=fixture();try{
  for(const [index,type]of ['iframe','worker'].entries()){
   const targetId='target-'+index,sessionId='session-'+index;
   f.reply({method:'Target.attachedToTarget',params:{sessionId,targetInfo:{targetId,type,url:origins[1]+'/frame'}}});
   if(type==='iframe'){
    const read=f.pipe.command('Page.getFrameTree',{},sessionId);f.reply({id:1,result:{frameTree:{frame:{id:targetId,parentId:'own-page'}}}});await read;
    assert.throws(()=>f.pipe.command('Page.navigate',{url:origins[1]+'/own'},sessionId));
    f.reply({method:'Target.targetInfoChanged',params:{targetInfo:{targetId,type,url:'https://example.com/'}}});assert.throws(()=>f.pipe.command('Page.getFrameTree',{},sessionId));
   }else assert.throws(()=>f.pipe.command('Page.getFrameTree',{},sessionId));
  }
 }finally{f.pipe.close();}
});
