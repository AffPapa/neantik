// Own fixed endpoints only. This is a measurement fixture, not product relay code.
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import crypto from 'node:crypto';

export function frame(payload, opcode = 1) {
  const bytes = Buffer.from(payload); assert(bytes.length < 126);
  return Buffer.concat([Buffer.from([0x80 | opcode, bytes.length]), bytes]);
}

export function decodeClientFrame(buffer) {
  if (buffer.length < 2) return null;
  assert.equal(buffer[0] & 0x70, 0); assert(buffer[0] & 0x80); assert(buffer[1] & 0x80);
  const size = buffer[1] & 127; assert(size < 126, 'Only small own frames permitted');
  if (buffer.length < size + 6) return null;
  const payload = Buffer.from(buffer.subarray(6, size + 6));
  for (let i = 0; i < size; i++) payload[i] ^= buffer[2 + i % 4];
  return {opcode: buffer[0] & 15, payload, consumed: size + 6};
}

const listen = server => new Promise((resolve, reject) => {
  server.once('error', reject); server.listen(0, '127.0.0.1', () => { server.off('error', reject); resolve(); });
});

export class WebSocketRouteFixture {
  constructor(nonce, tls) {
    assert(/^[a-f0-9]{32}$/.test(nonce)); this.nonce = nonce; this.tls = tls;
    this.sockets = new Set(); this.proxySockets = new Set(); this.upstreams = new Set();
    this.peers = new Set(); this.events = []; this.phase = 'initial'; this.transitions = [];
  }
  track(socket, proxy = false) {
    this.sockets.add(socket); if (proxy) this.proxySockets.add(socket);
    socket.on('error', () => {});
    socket.once('close', () => { this.sockets.delete(socket); this.proxySockets.delete(socket); this.upstreams.delete(socket); });
    return socket;
  }
  async start() {
    for (const protocol of ['ws', 'wss']) {
      const server = protocol === 'ws' ? http.createServer() : https.createServer(this.tls);
      server.on('request', (_req, res) => { res.writeHead(400); res.end(); });
      server.on('connection', socket => this.track(socket));
      server.on('upgrade', (req, socket, head) => this.upgrade(protocol, req, socket, head));
      await listen(server); this[protocol] = server;
    }
    this.proxy = http.createServer((_req, res) => { res.writeHead(403); res.end(); });
    this.proxy.on('connection', socket => this.track(socket, true));
    this.proxy.on('connect', (req, client, head) => {
      const allowed = ['ws', 'wss'].map(p => '127.0.0.1:' + this[p].address().port);
      if (this.phase === 'blocked' || !allowed.includes(req.url)) { client.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return; }
      const port = Number(req.url.split(':')[1]);
      const upstream = this.track(net.connect({host: '127.0.0.1', port}), true); this.upstreams.add(upstream);
      upstream.once('connect', () => {
        const key = upstream.localPort + ':' + port; this.peers.add(key);
        this.events.push({kind: 'tunnel', phase: this.phase, protocol: port === this.ws.address().port ? 'ws' : 'wss'});
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n'); if (head.length) upstream.write(head);
        client.pipe(upstream); upstream.pipe(client);
        upstream.once('close', () => { this.peers.delete(key); client.destroy(); });
        client.once('close', () => upstream.destroy());
      });
      upstream.once('error', () => client.destroy());
    });
    // Chromium uses CONNECT for this configured HTTP proxy, including ws.
    // An unexpected absolute-form upgrade must fail, not silently go Direct.
    this.proxy.on('upgrade', (_req, socket) => socket.destroy());
    await listen(this.proxy); this.proxyPort = this.proxy.address().port; return this;
  }
  urls(phase) {
    assert(['initial', 'blocked', 'recovered'].includes(phase));
    return Object.fromEntries(['ws', 'wss'].map(p => [p, `${p}://127.0.0.1:${this[p].address().port}/echo?nonce=${this.nonce}&phase=${phase}`]));
  }
  upgrade(protocol, req, socket, head) {
    this.track(socket);
    try {
      const url = new URL(req.url, 'http://own.invalid');
      assert.equal(url.pathname, '/echo'); assert.equal(url.searchParams.get('nonce'), this.nonce);
      const phase = url.searchParams.get('phase'); assert.equal(phase, this.phase);
      assert.equal(req.headers.origin, this.origin); assert.equal(req.headers['sec-websocket-version'], '13');
      const key = req.headers['sec-websocket-key']; assert(typeof key === 'string' && Buffer.from(key, 'base64').length === 16);
      const localPort = this[protocol].address().port;
      const route = this.peers.has(socket.remotePort + ':' + localPort) ? 'proxy' : 'direct';
      const event = {kind: 'handshake', phase, protocol, route, echoed: false, closed: false}; this.events.push(event);
      const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
      let pending = Buffer.alloc(0);
      const receive = bytes => {
        try {
          pending = Buffer.concat([pending, bytes]); assert(pending.length <= 4096);
          for (;;) {
            const f = decodeClientFrame(pending); if (!f) break; pending = pending.subarray(f.consumed);
            if (f.opcode === 8) { socket.end(frame(f.payload, 8)); return; }
            if (f.opcode === 9) { socket.write(frame(f.payload, 10)); continue; }
            assert.equal(f.opcode, 1); assert.equal(f.payload.toString(), `own:${this.nonce}:${phase}:${protocol}`);
            event.echoed = true; socket.write(frame(f.payload));
          }
        } catch { socket.destroy(); }
      };
      socket.on('data', receive); socket.once('close', () => { event.closed = true; });
      // HTTP-upgraded sockets can remain half-open after a proxy sends FIN.
      // Complete the owned peer's TCP shutdown; do not fabricate a WS close.
      socket.once('end', () => socket.end());
      if (head.length) receive(head);
    } catch { socket.destroy(); }
  }
  async transition(phase) {
    assert((this.phase === 'initial' && phase === 'blocked') || (this.phase === 'blocked' && phase === 'recovered'));
    this.phase = phase; this.transitions.push(phase);
    if (phase === 'blocked') {
      // Stop the actual proxy listener and all accepted/tunnel sockets.
      for (const socket of this.proxySockets) socket.destroy();
      await new Promise(resolve => this.proxy.close(resolve));
      assert.equal(this.proxy.listening, false);
    } else {
      await new Promise((resolve, reject) => {
        this.proxy.once('error', reject); this.proxy.listen(this.proxyPort, '127.0.0.1', () => { this.proxy.off('error', reject); resolve(); });
      });
      assert.equal(this.proxy.address().port, this.proxyPort);
    }
    return this.urls(phase);
  }
  async close() {
    const closed = [...this.sockets].map(socket => new Promise(resolve => { socket.once('close', resolve); socket.destroy(); }));
    await Promise.all([...closed, ...[this.proxy, this.ws, this.wss].filter(Boolean).map(server => new Promise(resolve => {
      if (!server.listening) { resolve(); return; } server.close(resolve);
    }))]);
    return {listenersClosed: [this.proxy, this.ws, this.wss].filter(Boolean).every(s => !s.listening), socketsRemaining: this.sockets.size};
  }
}
