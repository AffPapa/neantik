#!/usr/bin/env node
// Local, synthetic Device Memory control for one exact packaged Chromium app.
// No user profile, external host, cookie, or full request header is recorded.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

export function isCoherent(js, modern, legacy) {
  return typeof js === 'number' && Number.isFinite(js) && js > 0 &&
    modern === String(js) && legacy === String(js);
}

if (process.argv[2] === '--self-test') {
  assert.equal(isCoherent(8, '8', '8'), true);
  assert.equal(isCoherent(8, '32', '32'), false);
  assert.equal(isCoherent(8, null, '8'), false);
  console.log('Device Memory comparator controls passed.');
  process.exit(0);
}

if (process.argv.length !== 3) {
  console.error('Usage: verify-device-memory-coherence.mjs /absolute/path/to/NeAntik.app');
  process.exit(64);
}

const app = process.argv[2];
if (!path.isAbsolute(app) || !fs.statSync(app, { throwIfNoEntry: false })?.isDirectory()) {
  console.error('The packaged app must be an existing absolute directory.');
  process.exit(66);
}
const executable = path.join(
  app, 'Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser');
if (!fs.statSync(executable, { throwIfNoEntry: false })?.isFile()) {
  console.error('The packaged Chromium executable is unavailable.');
  process.exit(66);
}

const profile = fs.mkdtempSync('/private/tmp/neantik-memory-control-');
let navigationHeaders = null;
const server = http.createServer((request, response) => {
  response.setHeader('Accept-CH', 'Sec-CH-Device-Memory, Device-Memory');
  response.setHeader('Cache-Control', 'no-store');
  if (request.url?.startsWith('/navigation')) {
    navigationHeaders = {
      modern: request.headers['sec-ch-device-memory'] ?? null,
      legacy: request.headers['device-memory'] ?? null,
    };
  }
  if (request.url?.startsWith('/headers')) {
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({
      modern: request.headers['sec-ch-device-memory'] ?? null,
      legacy: request.headers['device-memory'] ?? null,
    }));
  } else {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end('<!doctype html><meta charset="utf-8"><title>Local memory control</title>');
  }
});

function command(socket, method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = Math.floor(Math.random() * 1_000_000_000);
    const timer = setTimeout(() => reject(new Error(`${method} timed out`)), 10_000);
    const onMessage = event => {
      try {
        const data = JSON.parse(event.data);
        if (data.id !== id) return;
        clearTimeout(timer);
        socket.removeEventListener('message', onMessage);
        if (data.error) reject(new Error(`${method} failed`));
        else resolve(data.result);
      } catch { /* Ignore unrelated CDP events. */ }
    };
    socket.addEventListener('message', onMessage);
    socket.send(JSON.stringify({ id, method, params }));
  });
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    socket.addEventListener('open', () => resolve(socket), { once: true });
    socket.addEventListener('error', () => reject(new Error('Local CDP socket failed')), { once: true });
  });
}

async function waitForExit(child, milliseconds) {
  if (child.exitCode !== null) return true;
  return Promise.race([
    new Promise(resolve => child.once('exit', () => resolve(true))),
    delay(milliseconds).then(() => false),
  ]);
}

let child;
let browserSocket;
try {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  child = spawn(executable, [
    `--user-data-dir=${profile}`,
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=0',
    '--remote-allow-origins=http://neantik.local',
    '--no-first-run',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-sync',
    '--disable-extensions',
    `${origin}/`,
  ], {
    env: { ...process.env, NEANTIK_PROFILE_SEED: '21' },
    stdio: 'ignore',
  });

  let port;
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const marker = path.join(profile, 'DevToolsActivePort');
    if (fs.existsSync(marker)) {
      port = Number(fs.readFileSync(marker, 'utf8').split('\n')[0]);
      break;
    }
    if (child.exitCode !== null) throw new Error('Packaged browser exited before CDP readiness');
    await delay(125);
  }
  if (!port) throw new Error('Packaged browser did not reach CDP readiness');

  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  browserSocket = await connect(version.webSocketDebuggerUrl);
  let page;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    page = targets.find(target => target.type === 'page' && target.url === `${origin}/`);
    if (page) break;
    await delay(125);
  }
  if (!page) throw new Error('The local control page did not open');

  const pageSocket = await connect(page.webSocketDebuggerUrl);
  try {
    // The first navigation teaches Chromium the origin's Accept-CH policy.
    // The second probes the browser-owned navigation path; fetch below probes
    // the separate renderer-owned subresource path.
    await command(pageSocket, 'Page.navigate', { url: `${origin}/navigation` });
    let ready = false;
    for (let attempt = 0; attempt < 80; attempt += 1) {
      try {
        const state = await command(pageSocket, 'Runtime.evaluate', {
          expression: 'location.pathname === "/navigation" && document.readyState === "complete"',
          returnByValue: true,
        });
        if (state.result.value === true) {
          ready = true;
          break;
        }
      } catch { /* Navigation may replace the execution context. */ }
      await delay(125);
    }
    if (!ready || !navigationHeaders) {
      throw new Error('The Client Hints navigation probe did not complete');
    }
    const evaluated = await command(pageSocket, 'Runtime.evaluate', {
      expression: `(async () => {
        const headers = await (await fetch('/headers?probe=1')).json();
        return JSON.stringify({js: navigator.deviceMemory, ...headers});
      })()`,
      awaitPromise: true,
      returnByValue: true,
    });
    const observed = JSON.parse(evaluated.result.value);
    const coherent =
      isCoherent(observed.js, navigationHeaders.modern, navigationHeaders.legacy) &&
      isCoherent(observed.js, observed.modern, observed.legacy);
    console.log(JSON.stringify({
      js: observed.js,
      navigation: navigationHeaders,
      subresource: { modern: observed.modern, legacy: observed.legacy },
      coherent,
    }));
    if (!coherent) process.exitCode = 1;
  } finally {
    pageSocket.close();
  }
  // The profile is disposable, but ask Chromium to flush and quit normally.
  browserSocket.send(JSON.stringify({ id: 1, method: 'Browser.close' }));
  await waitForExit(child, 10_000);
} catch (error) {
  console.error(`Device Memory control failed: ${error.message}`);
  process.exitCode = 1;
} finally {
  browserSocket?.close();
  if (child && child.exitCode === null) {
    child.kill('SIGTERM');
    if (!await waitForExit(child, 5_000)) child.kill('SIGKILL');
  }
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(profile, { recursive: true, force: true });
}
