// Read/write only synthetic markers in the fixture's own origin/profile.
(async () => {
  const {nonce, phase, marker} = document.documentElement.dataset;
  const out = {schemaVersion: 1, nonce, phase, errors: []};
  let db;
  const request = r => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
  try {
    const open = indexedDB.open('neantik-own-cohort-isolation', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('own'); db = await request(open);
    const cache = await caches.open('neantik-own-cohort-isolation');
    const snapshot = async () => ({localStorage: localStorage.getItem('neantik-own-marker'),
      sessionStorage: sessionStorage.getItem('neantik-own-marker'),
      cookie: document.cookie.split('; ').find(x => x.startsWith('neantik_own_marker='))?.split('=')[1] ?? null,
      indexedDB: (await request(db.transaction('own').objectStore('own').get('marker'))) ?? null,
      cacheStorage: await (await cache.match('/own-marker'))?.text() ?? null,
      workerActive: !!(await navigator.serviceWorker.getRegistration('/'))?.active});
    const raw = await navigator.userAgentData.getHighEntropyValues(['platformVersion', 'architecture', 'bitness']);
    const canvas = document.createElement('canvas'); canvas.width = 128; canvas.height = 32;
    const ctx = canvas.getContext('2d'), gradient = ctx.createLinearGradient(0, 0, 128, 32);
    gradient.addColorStop(0, '#123456'); gradient.addColorStop(1, '#cd8642');
    ctx.fillStyle = gradient; ctx.fillRect(0, 0, 128, 32); ctx.strokeStyle = '#641fa8';
    for (let x = 1; x < 128; x += 7) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(128 - x, 32); ctx.stroke(); }
    const readCanvas = async () => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', ctx.getImageData(0, 0, 128, 32).data))).map(b => b.toString(16).padStart(2, '0')).join('');
    const gl = document.createElement('canvas').getContext('webgl'), renderer = gl?.getExtension('WEBGL_debug_renderer_info');
    if (!renderer) throw Error('Missing-WebGL-renderer');
    out.identity = {cpu: navigator.hardwareConcurrency, memory: navigator.deviceMemory,
      screen: [screen.width, screen.height, screen.availWidth, screen.availHeight, screen.colorDepth, devicePixelRatio].join('x'),
      renderer: gl.getParameter(renderer.UNMASKED_RENDERER_WEBGL),
      hints: Object.fromEntries(['platform', 'platformVersion', 'architecture', 'bitness', 'mobile'].map(k => [k, raw[k]]))};
    gl.getExtension('WEBGL_lose_context')?.loseContext();
    out.canvas = {first: await readCanvas(), repeat: await readCanvas()}; out.before = await snapshot();
    if (phase.endsWith('write') || phase === 'wrong-root') {
      const empty = Object.entries(out.before).every(([key, value]) => key === 'workerActive' ? value === false : value === null);
      if (!empty) {
        out.writeRefused = true; out.after = await snapshot();
        if (phase !== 'wrong-root') throw Error('Unexpected-existing-owned-state');
      } else {
        if (phase === 'wrong-root') throw Error('Negative-control-did-not-find-A-state');
        localStorage.setItem('neantik-own-marker', marker); sessionStorage.setItem('neantik-own-marker', marker);
        document.cookie = `neantik_own_marker=${marker}; Path=/; Max-Age=3600; SameSite=Lax`;
        await new Promise((resolve, reject) => { const tx = db.transaction('own', 'readwrite');
          tx.objectStore('own').put(marker, 'marker'); tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error); });
        await cache.put('/own-marker', new Response(marker));
        await navigator.serviceWorker.register('/worker.js', {scope: '/'}); await navigator.serviceWorker.ready;
        out.writeRefused = false; out.after = await snapshot();
      }
    } else {
      if (phase !== 'a-return') throw Error('Unknown-phase');
      out.writeRefused = false; out.after = await snapshot();
    }
  } catch (error) { out.errors.push(error.message); }
  finally { db?.close(); }
  await fetch('/result', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(out)});
})().catch(() => {});
