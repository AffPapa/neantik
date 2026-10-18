// Fixed own synthetic data only. No CDP, account data or unrelated origin.
function ownDurabilityArm(event, fence) {
  const evidence = {trusted: event?.isTrusted === true, sticky: navigator.userActivation?.hasBeenActive === true};
  removeEventListener('beforeunload', fence);
  if (evidence.trusted && evidence.sticky) addEventListener('beforeunload', fence);
  return evidence;
}

(async () => {
  const config = globalThis.OWN_DURABILITY;
  if (!config || config.nonce !== document.body.dataset.owned) throw Error('owned-document');
  const result = {phase: config.phase, before: null, after: null, errors: [], wrote: false, strictIDB: false};
  const request = operation => new Promise((resolve, reject) => { operation.onsuccess = () => resolve(operation.result); operation.onerror = () => reject(operation.error); });
  let db;
  try {
    const open = indexedDB.open('neantik-owned-close-durability', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('owned'); db = await request(open);
    const cache = await caches.open('neantik-owned-close-durability');
    const snapshot = async () => ({
      cookie: document.cookie.split('; ').find(item => item.startsWith('neantik_owned_close='))?.split('=')[1] ?? null,
      localStorage: localStorage.getItem('neantik-owned-close'), sessionStorage: sessionStorage.getItem('neantik-owned-close'),
      indexedDB: (await request(db.transaction('owned').objectStore('owned').get('marker'))) ?? null,
      cacheStorage: await (await cache.match('/owned-cache-marker'))?.text() ?? null,
    });
    result.before = await snapshot();
    if (config.phase === 'write') {
      if (!Object.values(result.before).every(value => value === null)) throw Error('unexpected-existing-owned-data');
      localStorage.setItem('neantik-owned-close', config.marker); sessionStorage.setItem('neantik-owned-close', config.marker);
      document.cookie = 'neantik_owned_close=' + config.marker + '; Path=/; Max-Age=3600; SameSite=Lax';
      await new Promise((resolve, reject) => {
        const tx = db.transaction('owned', 'readwrite', {durability: 'strict'});
        result.strictIDB = tx.durability === 'strict'; tx.objectStore('owned').put(config.marker, 'marker');
        tx.oncomplete = resolve; tx.onerror = () => reject(Error('idb-write')); tx.onabort = () => reject(Error('idb-abort'));
      });
      await cache.put('/owned-cache-marker', new Response(config.marker)); result.wrote = true;
    } else if (config.phase !== 'read') throw Error('unknown-phase');
    result.after = await snapshot();
    const response = await fetch('/owned-receipt?nonce=' + config.nonce, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(result), cache: 'no-store', credentials: 'omit'});
    if (!response.ok) throw Error('owned-receipt-refused');
    document.querySelector('#status').textContent = 'Owned data observation complete: ' + config.phase;
    if (config.phase === 'write') {
      const fence = event => { event.preventDefault(); event.returnValue = ''; };
      document.querySelector('#hold').onclick = event => {
        const evidence = ownDurabilityArm(event, fence);
        document.querySelector('#hold-state').textContent = (evidence.trusted && evidence.sticky ? 'Own close fence armed' : 'Own close fence not armed') + '; trusted=' + evidence.trusted + '; sticky=' + evidence.sticky;
      };
      document.querySelector('#release').onclick = () => { removeEventListener('beforeunload', fence); document.querySelector('#hold-state').textContent = 'Own close fence disarmed'; };
    }
  } catch (error) { document.querySelector('#status').textContent = 'Own data observation failed'; }
  finally { db?.close(); }
})().catch(() => { document.querySelector('#status').textContent = 'Own data result unavailable'; });
