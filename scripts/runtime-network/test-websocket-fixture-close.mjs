// Own TCP FIN/drain control, no browser or OS setting. Regression for the
// retained protected1 harness failure; crypto material is synthetic/disposable.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {WebSocketRouteFixture} from './websocket-fixture.mjs';

const root = fs.mkdtempSync('/private/tmp/neantik-own-ws-wire.'); fs.chmodSync(root, 0o700);
let fixture; const clients = new Set();
const until = async fn => { for (let i = 0; i < 100; i++) { if (fn()) return true; await delay(10); } return false; };
try {
  const keyFile = root + '/key.pem', certFile = root + '/cert.pem';
  assert.equal(spawnSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyFile, '-out', certFile,
    '-subj', '/CN=localhost', '-days', '1'], {stdio: 'ignore'}).status, 0); fs.chmodSync(keyFile, 0o600);
  const nonce = crypto.randomBytes(16).toString('hex');
  fixture = await new WebSocketRouteFixture(nonce, {key: fs.readFileSync(keyFile), cert: fs.readFileSync(certFile)}).start();
  fixture.origin = 'http://127.0.0.1:1';
  async function open(proxy) {
    const socket = net.connect(proxy ? fixture.proxyPort : fixture.ws.address().port, '127.0.0.1'); clients.add(socket);
    socket.on('error', () => {}); socket.on('end', () => socket.end()); socket.once('close', () => clients.delete(socket));
    await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });
    let received = ''; socket.on('data', bytes => { received += bytes.toString(); });
    if (proxy) { socket.write('CONNECT 127.0.0.1:' + fixture.ws.address().port + ' HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'); assert(await until(() => received.includes('200 Connection Established'))); received = ''; }
    const key = crypto.randomBytes(16).toString('base64');
    socket.write('GET /echo?nonce=' + nonce + '&phase=initial HTTP/1.1\r\nHost: localhost\r\nOrigin: ' + fixture.origin + '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + key + '\r\n\r\n');
    assert(await until(() => received.includes('101 Switching Protocols')));
    const bytes = Buffer.from(`own:${nonce}:initial:ws`), mask = Buffer.from([1, 2, 3, 4]);
    socket.write(Buffer.concat([Buffer.from([0x81, bytes.length | 0x80]), mask, Buffer.from(bytes.map((v, i) => v ^ mask[i % 4]))]));
    assert(await until(() => fixture.events.filter(e => e.kind === 'handshake' && e.echoed).length === (proxy ? 2 : 1))); return socket;
  }
  const direct = await open(false); direct.end();
  assert(await until(() => fixture.events.find(e => e.kind === 'handshake' && e.route === 'direct')?.closed === true), 'FIN must close upgraded origin socket');
  await open(true); await fixture.transition('blocked');
  assert(await until(() => fixture.events.find(e => e.kind === 'handshake' && e.route === 'proxy')?.closed === true), 'Proxy FIN must close upgraded origin socket');
  const closed = await fixture.close(); assert.deepEqual(closed, {listenersClosed: true, socketsRemaining: 0});
  assert(await until(() => clients.size === 0));
  console.log(JSON.stringify({status: 'passed-owned-upgraded-socket-fin-and-drain', positiveControls: 2, actualBrowser: false, fixture: closed}));
} finally {
  for (const socket of clients) socket.destroy();
  if (fixture) await fixture.close();
  fs.rmSync(root, {recursive: true}); assert(!fs.existsSync(root));
}
