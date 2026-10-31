// Real loopback protocol tests only; no browser or font API qualification.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import {createFontPolicyFixture} from './font-policy-fixture.mjs';
const own=()=>({sameProcessGroup:true,runtimePathBound:true,generationSHA256:'a'.repeat(64)});
const request=(f,path,nonce,options={})=>fetch(f.origin+path+'?nonce='+nonce,options);
const post=(f,nonce,body,origin=f.origin)=>request(f,'/result',nonce,{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:typeof body==='string'?body:JSON.stringify(body)});

test('missing/wrong nonce is refused before custody is considered',async()=>{
 let calls=0;const f=await createFontPolicyFixture({browserCustody:()=>{calls++;return own();}});
 try {const s=f.begin();assert.equal((await fetch(f.origin+'/own')).status,404);assert.equal((await request(f,'/own','b'.repeat(32))).status,404);assert.equal(calls,0);assert.equal(f.observation().result,null);}
 finally {await f.close();}
});
test('unbound kernel peer and observer failure cannot fetch or submit',async()=>{
 for(const callback of [()=>null,()=>({...own(),runtimePathBound:false}),()=>{throw Error('synthetic failure');}]) {
  const f=await createFontPolicyFixture({browserCustody:callback});
  try {const s=f.begin();assert.equal((await fetch(s.url)).status,403);assert.equal((await post(f,s.nonce,{schemaVersion:1,nonce:s.nonce,realms:[]})).status,403);assert.equal(f.observation().result,null);}
  finally {await f.close();}
 }
});
test('owned document/JS/TTF/WOFF2 have exact MIME and pinned bytes',async()=>{
 const f=await createFontPolicyFixture({browserCustody:own});
 try {const s=f.begin();const page=await fetch(s.url);assert.equal(page.status,200);assert.match(page.headers.get('content-type'),/text\/html/);const html=await page.text();assert(html.includes('runOwnFontPolicyRealm'));assert(html.includes(s.nonce));const encoded=html.match(/const source=("(?:[^"\\]|\\.)*")\+'/);assert(encoded);const workerSource=JSON.parse(encoded[1]);assert.equal(workerSource,fs.readFileSync(new URL('./font-policy-realm.js',import.meta.url),'utf8'));new vm.Script(workerSource);
  for(const [path,type] of [['/realm.js','text/javascript'],['/canary.ttf','font/ttf'],['/ahem.woff2','font/woff2']]){const response=await request(f,path,s.nonce);assert.equal(response.status,200);assert.equal(response.headers.get('content-type'),type);assert((await response.arrayBuffer()).byteLength>0);}
  assert.equal(f.observation().requests.length,4);assert.equal(f.resourceHashes.canarySHA256,'f442b055b908db3c277bb603d0ad188c385e2050312b0ee6a6ae6512c3b266de');
 }finally {await f.close();}
});
test('wrong origin, malformed envelope and oversized result are refused',async()=>{
 const f=await createFontPolicyFixture({browserCustody:own});
 try {const s=f.begin();const body={schemaVersion:1,nonce:s.nonce,realms:[]};assert.equal((await post(f,s.nonce,body,'http://example.invalid')).status,409);assert.equal((await post(f,s.nonce,{...body,nonce:'b'.repeat(32)})).status,400);assert.equal((await post(f,s.nonce,'x'.repeat(131073))).status,400);assert.equal(f.observation().result,null);}
 finally {await f.close();}
});
test('result is one-shot and prior session cannot write into next session',async()=>{
 const f=await createFontPolicyFixture({browserCustody:own});
 try {const s=f.begin(),body={schemaVersion:1,nonce:s.nonce,realms:[]};assert.equal((await post(f,s.nonce,body)).status,204);assert.equal((await post(f,s.nonce,body)).status,409);assert.deepEqual(f.finish().result,body);const next=f.begin();assert.notEqual(next.nonce,s.nonce);assert.equal((await post(f,s.nonce,body)).status,404);assert.equal(f.observation().result,null);}
 finally {await f.close();}
});

test('explicit owned nonce is retained and malformed nonce never activates a session',async()=>{
 const f=await createFontPolicyFixture({browserCustody:own});
 try {assert.throws(()=>f.begin('not-a-nonce'));assert.equal(f.observation(),null);const nonce='c'.repeat(32),s=f.begin(nonce);assert.equal(s.nonce,nonce);assert.equal((await fetch(s.url)).status,200);}
 finally {await f.close();}
});
