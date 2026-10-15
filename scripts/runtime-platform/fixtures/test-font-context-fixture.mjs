// Own loopback protocol and source-builder controls. No browser qualification.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import vm from 'node:vm';
import fs from 'node:fs';
import {createFontContextFixture,fontContextNames,fontWorkerSource,fontWorkletSource,fontFrameMarkup} from './font-context-fixture.mjs';
const nonce='a'.repeat(32),contextNonce='b'.repeat(32);
const own=()=>({sameProcessGroup:true,runtimePathBound:true,generationSHA256:'c'.repeat(64)});
const make=(extra={})=>createFontContextFixture({browserCustody:own,confirm:async()=>({confirmed:true,uniqueContext:true}),...extra});
test('all context source builders parse, with fixed scope and safe script embedding',()=>{
 assert.equal(fontContextNames.length,9);assert.equal(new Set(fontContextNames).size,9);
 for(const kind of ['dedicated','shared','service'])new vm.Script(fontWorkerSource(kind,nonce));
 new vm.Script(fs.readFileSync(new URL('./font-generic-realm.js',import.meta.url),'utf8'));
 new vm.Script(fontWorkletSource(contextNonce));new vm.Script(fs.readFileSync(new URL('./font-context-page.js',import.meta.url),'utf8'));
 for(const bad of ['','../escape','<script>'])assert.throws(()=>fontWorkerSource('service',bad));
 assert.throws(()=>fontWorkerSource('unknown',nonce));
 const html=fontFrameMarkup({nonce,contextNonce,origin:'http://localhost:12345',parentOrigin:'http://127.0.0.1:12346',fontURL:'own</script>marker'});
 const scripts=Array.from(html.matchAll(/<script>([\s\S]*?)<\/script>/g),m=>m[1]);assert.equal(scripts.length,1);new vm.Script(scripts[0]);assert(!scripts[0].includes('</script>'));
 assert.throws(()=>fontFrameMarkup({nonce,contextNonce,origin:'https://example.com',parentOrigin:'http://127.0.0.1:12346'}));
});
test('nonce and kernel custody are required on both owned sites',async()=>{
 const f=await make({browserCustody:()=>null});try{
  const s=f.begin(nonce);assert.equal((await fetch(f.origins[0]+'/own')).status,404);assert.equal((await fetch(s.url)).status,403);
  assert.equal((await fetch(f.origins[1]+'/frame?nonce='+nonce+'&name=cross-origin%20OOPIF&contextNonce='+contextNonce)).status,403);
  assert.equal(f.observation().result,null);
 }finally{await f.close();}
});
test('owned routes provide exact resources and cross-site frames use same-site fonts',async()=>{
 const confirmed=[],f=await make({confirm:async(name,value)=>{confirmed.push([name,value]);return {confirmed:true,uniqueContext:true};}});
 try{
  const s=f.begin(nonce);assert.equal((await fetch(s.url)).status,200);
  for(const site of f.origins)for(const [route,mime] of [['/realm.js','text/javascript'],['/generic.js','text/javascript'],['/canary.ttf','font/ttf'],['/ahem.woff2','font/woff2']]){const response=await fetch(site+route+'?nonce='+nonce);assert.equal(response.status,200);assert.equal(response.headers.get('content-type'),mime);assert((await response.arrayBuffer()).byteLength>0);}
  const response=await fetch(f.origins[1]+'/frame?nonce='+nonce+'&name=cross-origin%20OOPIF&contextNonce='+contextNonce),html=await response.text();assert(html.includes(f.origins[1]+'/canary.ttf'));assert(html.includes('contextNonce'));
  const confirm=await fetch(f.origins[0]+'/confirm?nonce='+nonce+'&name=SharedWorker&contextNonce='+contextNonce);assert.equal((await confirm.json()).confirmed,true);assert.deepEqual(confirmed,[['SharedWorker',contextNonce]]);
  assert.equal((await fetch(f.origins[0]+'/confirm?nonce='+nonce+'&name=unknown&contextNonce='+contextNonce)).status,404);
  assert.equal((await (await fetch(f.origins[0]+'/phase?nonce='+nonce)).json()).teardown,false);f.requestTeardown();assert.equal((await (await fetch(f.origins[0]+'/phase?nonce='+nonce)).json()).teardown,true);
 }finally{await f.close();}
});
test('result/cleanup are one shot, bounded and origin-bound, without accepting semantic PASS',async()=>{
 const f=await make();try{
  f.begin(nonce);const post=(body,origin=f.origins[0],route='/result')=>fetch(f.origins[0]+route+'?nonce='+nonce,{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:typeof body==='string'?body:JSON.stringify(body)});
  const body={schemaVersion:1,nonce,results:[]};
  assert.equal((await post(body,'http://example.invalid')).status,409);assert.equal((await post({...body,nonce:contextNonce})).status,400);assert.equal((await post('x'.repeat(1048577))).status,400);assert.equal((await post({nonce})).status,400);
  assert.equal((await post(body)).status,204);assert.equal((await post(body)).status,409);
  assert.equal((await post({nonce,teardownAllowed:true,completed:1,errors:[]},f.origins[0],'/closed')).status,204);
  assert.equal(f.finish().result.results.length,0); // Protocol success is not nine-context semantic success.
  const next=f.begin();assert.notEqual(next.nonce,nonce);assert.equal((await post(body)).status,404);
 }finally{await f.close();}
});
