// One fixed synthetic WS scenario on the owned normal manager page. No CDP.
(async () => {
  const config = globalThis.OWN_MANAGER_WS;
  if (!config || config.nonce !== document.body.dataset.fixture) throw Error('owned-document');
  const result = {mode: config.mode, rows: [], held: null, errors: [], remaining: null};
  const sockets = new Set();
  const bounded = async (promise, label) => {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(Error(label)), 6000); })]); }
    finally { clearTimeout(timer); }
  };
  const control = async phase => {
    const response = await fetch(config.control + '&phase=' + phase, {cache: 'no-store', credentials: 'omit'});
    if (!response.ok) throw Error('owned-control');
    return response.json();
  };
  async function connect(phase, hold = false) {
    const socket = new WebSocket(config.websocket + '&phase=' + phase);
    sockets.add(socket);
    const row = {phase, opened: false, echoed: false, errored: false, closeCode: null};
    let closed;
    const exited = new Promise(resolve => { closed = resolve; });
    const finished = new Promise(resolve => {
      socket.onopen = () => { row.opened = true; socket.send('own:' + config.nonce + ':' + phase); };
      socket.onmessage = event => { row.echoed = event.data === 'own:' + config.nonce + ':' + phase; if (hold) resolve(); else socket.close(1000); };
      socket.onerror = () => { row.errored = true; };
      socket.onclose = event => { row.closeCode = event.code; sockets.delete(socket); closed(); resolve(); };
    });
    await bounded(finished, 'socket-operation-timeout'); result.rows.push(row);
    return {socket, row, exited};
  }
  try {
    await control('initial'); const held = await connect('initial', true);
    await control('blocked');
    if (config.mode === 'proxy-success') {
      await bounded(held.exited, 'live-tunnel-not-cut');
      result.held = {aborted: held.socket.readyState === WebSocket.CLOSED, closeCode: held.row.closeCode};
    } else {
      result.held = {stillOpen: held.socket.readyState === WebSocket.OPEN};
      held.socket.close(1000); await bounded(held.exited, 'direct-close-timeout');
    }
    await connect('blocked'); await control('recovered'); await connect('recovered');
  } catch (error) { result.errors.push(String(error.message).slice(0, 48)); }
  finally {
    for (const socket of sockets) socket.close();
    // A failure cannot report successful cleanup merely after calling close().
    try { await bounded(new Promise(resolve => { const poll = () => sockets.size ? setTimeout(poll, 10) : resolve(); poll(); }), 'socket-drain-timeout'); }
    catch (error) { result.errors.push(String(error.message)); }
    result.remaining = sockets.size;
    const response = await fetch(config.receipt + '&result=' + encodeURIComponent(JSON.stringify(result)), {cache: 'no-store', credentials: 'omit'});
    document.querySelector('#result').textContent = response.ok && !result.errors.length ? 'Owned WS observation complete' : 'Owned WS observation failed';
  }
})().catch(() => { document.querySelector('#result').textContent = 'Owned WS result unavailable'; });
