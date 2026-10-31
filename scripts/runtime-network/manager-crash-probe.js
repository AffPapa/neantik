// Own synthetic data. Receipt means API completion, not a universal disk flush.
async function ownCrashOpenStores(phase) {
  if (!['baseline','mutate','read'].includes(phase)) throw Error('unknown-store-phase');
  const name = 'neantik-own-crash';
  if (phase !== 'baseline') {
    if (!(await caches.has(name))) throw Error('existing-cache-missing');
    if (!(await indexedDB.databases()).some(d => d.name === name && d.version === 1)) throw Error('existing-database-missing');
  }
  const db = await new Promise((resolve,reject) => {
    const op = indexedDB.open(name,1);
    op.onupgradeneeded = () => {
      if (phase === 'baseline') op.result.createObjectStore('owned');
      else op.transaction.abort(); // A concurrent disappearance must not repair storage.
    };
    op.onsuccess = () => {
      if (!op.result.objectStoreNames.contains('owned')) {op.result.close(); reject(Error('existing-store-missing'));}
      else resolve(op.result);
    };
    op.onerror = () => reject(Error('existing-database-unavailable'));
  });
  try {return {db,cache:phase === 'read' ? null : await caches.open(name)};}
  catch (error) {db.close();throw error;}
}

(async () => {
  const c = globalThis.OWN_CRASH;
  if (!c || c.nonce !== document.body.dataset.owned) throw Error('owned-document');
  let db;
  const request = op => new Promise((resolve, reject) => {op.onsuccess = () => resolve(op.result); op.onerror = () => reject(op.error);});
  try {
    const stores = await ownCrashOpenStores(c.phase); db = stores.db;
    const cache = stores.cache;
    const cookie = name => document.cookie.split('; ').find(x => x.startsWith(name + '='))?.slice(name.length + 1) ?? null;
    const snapshot = async () => ({
      baseline: {cookie: cookie('neantik_crash_base'), localStorage: localStorage.getItem('neantik-crash-base'),
        indexedDB: (await request(db.transaction('owned').objectStore('owned').get('baseline'))) ?? null,
        cacheStorage: await (await caches.match('/own-crash-base', {cacheName:'neantik-own-crash'}))?.text() ?? null},
      fresh: {cookie: cookie('neantik_crash_fresh'), localStorage: localStorage.getItem('neantik-crash-fresh'),
        indexedDB: (await request(db.transaction('owned').objectStore('owned').get('committed'))) ?? null,
        cacheStorage: await (await caches.match('/own-crash-fresh', {cacheName:'neantik-own-crash'}))?.text() ?? null},
      aborted: (await request(db.transaction('owned').objectStore('owned').get('aborted'))) ?? null,
      sessionStorage: sessionStorage.getItem('neantik-crash-session'),
    });
    const result = {phase:c.phase, before:await snapshot(), after:null, wrote:false,
      strictCompleted:false, abortedAfterRequestSuccess:false, errors:[]};
    const strictWrite = (key, value, abort) => new Promise((resolve, reject) => {
      const tx = db.transaction('owned', 'readwrite', {durability:'strict'});
      if (tx.durability !== 'strict') {tx.abort(); reject(Error('strict-unavailable')); return;}
      let success = false;
      const op = tx.objectStore('owned').put(value, key);
      op.onsuccess = () => {success=true; if (abort) tx.abort();};
      tx.oncomplete = () => abort ? reject(Error('abort-unexpected-commit')) : resolve(true);
      tx.onabort = () => abort && success ? resolve(true) : reject(Error('unexpected-abort'));
      tx.onerror = () => reject(Error('transaction-error'));
    });
    if (c.phase === 'baseline') {
      await strictWrite('baseline', c.baseline, false);
      document.cookie = 'neantik_crash_base=' + c.baseline + '; Path=/; Max-Age=3600; SameSite=Lax';
      localStorage.setItem('neantik-crash-base', c.baseline);
      await cache.put('/own-crash-base', new Response(c.baseline));
      result.wrote = true; result.strictCompleted = true;
    } else if (c.phase === 'mutate') {
      // Separate keys retain the settled baseline for the crash comparison.
      await strictWrite('committed', c.fresh, false);
      result.strictCompleted = true;
      result.abortedAfterRequestSuccess = await strictWrite('aborted', c.fresh, true);
      document.cookie = 'neantik_crash_fresh=' + c.fresh + '; Path=/; Max-Age=3600; SameSite=Lax';
      localStorage.setItem('neantik-crash-fresh', c.fresh);
      sessionStorage.setItem('neantik-crash-session', c.fresh);
      await cache.put('/own-crash-fresh', new Response(c.fresh)); result.wrote = true;
    } else if (c.phase !== 'read') throw Error('unknown-phase');
    result.after = await snapshot();
    const response = await fetch('/own-crash-receipt?nonce=' + c.nonce, {method:'POST',
      headers:{'Content-Type':'application/json'},body:JSON.stringify(result),credentials:'omit',cache:'no-store'});
    if (!response.ok) throw Error('receipt-refused');
    document.querySelector('#status').textContent = 'Owned crash observation complete: ' + c.phase;
  } catch (_) {document.querySelector('#status').textContent = 'Own crash observation failed';}
  finally {db?.close();}
})().catch(() => {document.querySelector('#status').textContent = 'Own crash setup failed';});
