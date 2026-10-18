// Actual probe helper with controlled Web API lifecycle; not browser durability.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('./manager-crash-probe.js',import.meta.url),'utf8');
const helper = source.slice(0,source.indexOf('\n(async () => {'));
assert(helper.includes('async function ownCrashOpenStores'));
function setup(options={}) {
  const calls={dbOpen:0,cacheOpen:0,created:0,aborted:0,closed:0};
  let storeExists = options.storeExists !== false;
  const db={objectStoreNames:{contains:()=>storeExists},close:()=>calls.closed++,createObjectStore:()=>{calls.created++;storeExists=true;}};
  const context=vm.createContext({
    caches:{has:async()=>options.cacheExists!==false,open:async()=>{calls.cacheOpen++;return {}; }},
    indexedDB:{databases:async()=>options.dbExists===false?[]:[{name:'neantik-own-crash',version:1}],open:()=>{
      calls.dbOpen++;let aborted=false;
      const op={result:db,transaction:{abort:()=>{aborted=true;calls.aborted++;}}};
      queueMicrotask(()=>{if(options.upgrade)op.onupgradeneeded();if(aborted)op.onerror();else op.onsuccess();});
      return op;
    }},
  });
  vm.runInContext(helper,context);return {open:phase=>context.ownCrashOpenStores(phase),calls};
}
for(const phase of ['mutate','read']) {
  for(const missing of ['cacheExists','dbExists']) {
    const s=setup({[missing]:false});await assert.rejects(s.open(phase));
    assert.equal(s.calls.dbOpen,0);assert.equal(s.calls.cacheOpen,0);assert.equal(s.calls.created,0);
  }
  const raced=setup({upgrade:true});await assert.rejects(raced.open(phase));assert.equal(raced.calls.aborted,1);assert.equal(raced.calls.created,0);assert.equal(raced.calls.cacheOpen,0);
  const missingStore=setup({storeExists:false});await assert.rejects(missingStore.open(phase));assert.equal(missingStore.calls.closed,1);assert.equal(missingStore.calls.created,0);
}
const read=setup();await read.open('read');assert.equal(read.calls.cacheOpen,0);assert.equal(read.calls.created,0);
const mutate=setup();await mutate.open('mutate');assert.equal(mutate.calls.cacheOpen,1);assert.equal(mutate.calls.created,0);
const baseline=setup({upgrade:true,storeExists:false});await baseline.open('baseline');assert.equal(baseline.calls.created,1);assert.equal(baseline.calls.cacheOpen,1);
const unknown=setup();await assert.rejects(unknown.open('unknown'));assert.equal(unknown.calls.dbOpen,0);assert.equal(unknown.calls.cacheOpen,0);
console.log('Crash-store helper:3positive/9negative lifecycle controls PASS;not native qualification');
