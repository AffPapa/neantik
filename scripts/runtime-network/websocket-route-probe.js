// Synthetic payloads only. No page/account data, microphone or system settings.
(async () => {
  const nonce = document.documentElement.dataset.nonce, mode = document.documentElement.dataset.mode;
  const result = {kind: 'owned-websocket-route-operations', nonce, mode, rows: [], held: [], errors: []};
  const all = new Set();
  const bounded = (promise, label, ms = 6000) => {
    let timer; return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(Error(label)), ms); })]).finally(() => clearTimeout(timer));
  };
  const get = async phase => {
    const response = await fetch('/control?nonce=' + nonce + '&phase=' + phase, {cache: 'no-store'});
    if (!response.ok) throw Error('control'); return response.json();
  };
  async function connect(protocol, phase, url, hold = false) {
    const socket = new WebSocket(url); all.add(socket);
    const row = {protocol, phase, opened: false, echoed: false, errored: false, timedOut: false, closeCode: null};
    let resolveClosed; const closed = new Promise(resolve => { resolveClosed = resolve; });
    const completion = new Promise(resolve => {
      socket.addEventListener('open', () => { row.opened = true; socket.send(`own:${nonce}:${phase}:${protocol}`); });
      socket.addEventListener('message', event => {
        row.echoed = event.data === `own:${nonce}:${phase}:${protocol}`;
        if (hold) resolve(); else socket.close(1000);
      });
      socket.addEventListener('error', () => { row.errored = true; });
      socket.addEventListener('close', event => { row.closeCode = event.code; all.delete(socket); resolveClosed(); resolve(); });
    });
    try { await bounded(completion, 'socket-timeout'); }
    catch (error) { row.timedOut = true; socket.close(); throw error; }
    result.rows.push(row); return {socket, row, closed};
  }
  try {
    const urls = await get('initial'), held = [];
    for (const protocol of ['ws', 'wss']) held.push({protocol, ...await connect(protocol, 'initial', urls[protocol], true)});
    const blocked = await get('blocked');
    if (mode === 'protected') {
      for (const item of held) {
        await bounded(item.closed, 'active-tunnel-not-aborted');
        result.held.push({protocol: item.protocol, abortedByProxyStop: item.socket.readyState === WebSocket.CLOSED, closeCode: item.row.closeCode});
      }
    } else {
      // Positive bypass control: stopping the proxy must not close Direct sockets.
      await new Promise(resolve => setTimeout(resolve, 200));
      for (const item of held) {
        result.held.push({protocol: item.protocol, stillOpenAfterProxyStop: item.socket.readyState === WebSocket.OPEN});
        item.socket.close(1000); await bounded(item.closed, 'own-direct-close');
      }
    }
    for (const protocol of ['ws', 'wss']) await connect(protocol, 'blocked', blocked[protocol]);
    const recovered = await get('recovered');
    for (const protocol of ['ws', 'wss']) await connect(protocol, 'recovered', recovered[protocol]);
  } catch (error) { result.errors.push(String(error.message).slice(0, 60)); }
  finally {
    for (const socket of all) socket.close();
    result.socketsRemaining = all.size;
    await fetch('/result', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(result)});
    document.body.textContent = result.errors.length ? 'Own WS/WSS observation failed' : 'Own WS/WSS observation complete';
  }
})().catch(() => { document.body.textContent = 'Own WS/WSS result unavailable'; });
