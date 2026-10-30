import assert from 'node:assert/strict';import {test} from 'node:test';
import {createFontAccessFixture} from './font-access-fixture.mjs';
const nonce='a'.repeat(32),custody=()=>({sameProcessGroup:true,runtimePathBound:true,generationSHA256:'b'.repeat(64)});
test('own Font Access sites require nonce/host/kernel custody on both origins',async()=>{
 const fixture=await createFontAccessFixture({browserCustody:()=>null});try{const state=fixture.begin(nonce);assert.equal((await fetch(state.url)).status,403);assert.equal((await fetch(fixture.origins[1]+'/foreign?nonce='+nonce)).status,403);assert.equal((await fetch(fixture.origins[0]+'/access?nonce='+'c'.repeat(32))).status,404);}finally{await fixture.close();}
});
test('only fixed scripts and four-name foreign source served; ready/result one-shot and phase bounded',async()=>{
 const fixture=await createFontAccessFixture({browserCustody:custody});try{
  const state=fixture.begin(nonce),post=(route,value,origin=fixture.origins[0])=>fetch(fixture.origins[0]+route+'?nonce='+nonce,{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:typeof value==='string'?value:JSON.stringify(value)});
  assert.equal((await fetch(state.url)).status,200);for(const route of ['/sfnt.js','/access.js']){const response=await fetch(fixture.origins[0]+route+'?nonce='+nonce);assert.equal(response.status,200);assert.equal(response.headers.get('content-type'),'text/javascript');}
  const foreign=await(await fetch(fixture.origins[1]+'/foreign?nonce='+nonce)).text();assert(foreign.includes('Helvetica-Light'));assert(foreign.includes('postscriptNames:names'));
  assert.equal((await fetch(fixture.origins[1]+'/top-foreign?nonce='+nonce)).status,200);
  const topPost=(body,origin)=>fetch(fixture.origins[1]+'/top-result?nonce='+nonce,{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:JSON.stringify(body)});
  assert.equal((await topPost({nonce,error:false,value:{topLevel:true}},fixture.origins[0])).status,409);assert.equal((await topPost({nonce,error:false,value:{topLevel:true}},fixture.origins[1])).status,204);assert.equal(fixture.observation().topForeign.topLevel,true);
  assert.equal((await post('/ready',{nonce,ready:{}},fixture.origins[1])).status,409);assert.equal((await post('/ready',{nonce,ready:{}})).status,204);assert.equal((await post('/ready',{nonce,ready:{}})).status,400);
  assert.throws(()=>fixture.phase('global-grant'));fixture.phase('denied-initial');assert.equal((await(await fetch(fixture.origins[0]+'/phase?nonce='+nonce)).json()).phase,'denied-initial');
  assert.equal((await post('/step',{nonce,stage:{phase:'granted'}})).status,400);assert.equal((await post('/step',{nonce,stage:{phase:'denied-initial'}})).status,204);
  assert.equal((await post('/result','x'.repeat(32769))).status,400);assert.equal((await post('/result',{nonce,schemaVersion:1,stages:[],error:'incomplete'})).status,204);
  assert.equal((await post('/result',{nonce,schemaVersion:1,stages:[]})).status,400);const captured=fixture.finish();assert.equal(captured.result.error,'incomplete'); // Protocol receipt never means semantic PASS.
  assert.equal((await fetch(state.url)).status,404);
 }finally{await fixture.close();}
});
