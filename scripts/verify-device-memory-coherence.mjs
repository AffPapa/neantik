#!/usr/bin/env node
// Local, synthetic Device Memory control for one exact packaged Chromium app.
// No user profile, external host, cookie, or full request header is recorded.

import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

export function isCoherent(js, modern, legacy) {
  return typeof js === 'number' && Number.isFinite(js) && js > 0 &&
    modern === String(js) && legacy === String(js);
}

export function reportedVersion(product) {
  return typeof product === 'string' ? product.match(/^[^/]+\/(\d+\.\d+\.\d+\.\d+)$/)?.[1] ?? null : null;
}

export function isFixtureProcess(group, command, ownedGroup, root) {
  const marker = `--user-data-dir=${root}`;
  return group === ownedGroup || (` ${command} `).includes(` ${marker} `);
}

if (process.argv[2] === '--self-test') {
  assert.equal(isCoherent(8, '8', '8'), true);
  assert.equal(isCoherent(8, '32', '32'), false);
  assert.equal(isCoherent(8, null, '8'), false);
  assert.equal(isCoherent(Infinity, 'Infinity', 'Infinity'), false);
  assert.equal(isCoherent(NaN, 'NaN', 'NaN'), false);
  assert.equal(isCoherent('8', '8', '8'), false);
  assert.equal(isCoherent(8, '8', '32'), false);
  assert.equal(reportedVersion('Chrome/155.0.8059.40'), '155.0.8059.40');
  assert.notEqual(reportedVersion('Chrome/154.0.8037.98'), '155.0.8059.40');
  assert.equal(reportedVersion('155.0.8059.40'), null);
  assert.equal(isFixtureProcess(123, 'helper', 123, '/synthetic/root'), true);
  assert.equal(isFixtureProcess(456, 'helper --user-data-dir=/synthetic/root', 123, '/synthetic/root'), true);
  assert.equal(isFixtureProcess(456, 'helper --user-data-dir=/synthetic/root-other', 123, '/synthetic/root'), false);
  assert.equal(isFixtureProcess(456, 'unrelated', 123, '/synthetic/root'), false);
  assert.equal(await waitForExit({ exitCode: null, signalCode: 'SIGTERM' }, 1000), true);
  assert.equal(await waitForExit({ exitCode: null, signalCode: null }, 1), false);
  console.log('Device Memory comparator controls passed.');
  process.exit(0);
}

const expectedVersion = process.argv.length === 5 && process.argv[3] === '--expected-version'
  ? process.argv[4] : null;
if (process.argv.length !== 3 && !(expectedVersion && /^\d+\.\d+\.\d+\.\d+$/.test(expectedVersion))) {
  console.error('Usage: verify-device-memory-coherence.mjs /absolute/path/to/NeAntik.app [--expected-version 155.0.8059.40]');
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
const version = spawnSync('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-',
  path.join(app, 'Contents/Resources/NeAntik Browser.app/Contents/Info.plist')], { encoding: 'utf8' });
const chromiumVersion = version.stdout?.trim();
if (version.status !== 0 || !/^\d+\.\d+\.\d+\.\d+$/.test(chromiumVersion ?? '') ||
    (expectedVersion && expectedVersion !== chromiumVersion)) {
  console.error('Packaged Chromium version is missing or differs from the required version.');
  process.exit(65);
}
const executableSHA256 = crypto.createHash('sha256').update(fs.readFileSync(executable)).digest('hex');

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
    const timer = setTimeout(() => {
      socket.removeEventListener('message', onMessage);
      reject(new Error(`${method} timed out`));
    }, 10_000);
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
    const timer = setTimeout(() => { socket.close(); reject(new Error('Local CDP socket timeout')); }, 8000);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(socket); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timer); socket.close(); reject(new Error('Local CDP socket failed')); }, { once: true });
  });
}

async function waitForExit(child, milliseconds) {
  const deadline = Date.now() + milliseconds;
  while (child.exitCode === null && child.signalCode === null && Date.now() < deadline) await delay(100);
  return child.exitCode !== null || child.signalCode !== null;
}

function fixtureProcessCount() {
  // Process arguments remain in this local process and are never printed or
  // written into evidence. Only the owned group and exact temporary root match.
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,pgid=,command='], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error('Own fixture process inventory unavailable');
  return result.stdout.split('\n').filter(line => {
    const parsed = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
    return parsed && isFixtureProcess(Number(parsed[2]), parsed[3], ownGroup, profile);
  }).length;
}

async function waitForFixtureExit(milliseconds) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) {
    if (fixtureProcessCount() === 0) return true;
    await delay(125);
  }
  return fixtureProcessCount() === 0;
}

let child;
let browserSocket;
let observedReport;
let cleanupSucceeded = false;
let startupFailed = false;
let ownGroup;
let cdpChromiumVersion;
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
    detached: true,
  });
  ownGroup = child.pid;
  child.once('error', () => { startupFailed = true; });

  let port;
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const marker = path.join(profile, 'DevToolsActivePort');
    if (fs.existsSync(marker)) {
      port = Number(fs.readFileSync(marker, 'utf8').split('\n')[0]);
      if (Number.isInteger(port) && port > 0 && port <= 65535) break;
      port = undefined;
    }
    if (startupFailed || child.exitCode !== null || child.signalCode !== null) throw new Error('Packaged browser exited before CDP readiness');
    await delay(125);
  }
  if (!port) throw new Error('Packaged browser did not reach CDP readiness');

  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(1500) })).json();
  cdpChromiumVersion = reportedVersion(version.Browser);
  if (cdpChromiumVersion !== chromiumVersion) throw new Error('Running Chromium version differs from packaged identity');
  browserSocket = await connect(version.webSocketDebuggerUrl);
  let page;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(1500) })).json();
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
    if (evaluated.exceptionDetails || typeof evaluated.result?.value !== 'string') throw new Error('Local memory observation failed');
    const observed = JSON.parse(evaluated.result.value);
    const coherent =
      isCoherent(observed.js, navigationHeaders.modern, navigationHeaders.legacy) &&
      isCoherent(observed.js, observed.modern, observed.legacy);
    observedReport = {
      chromiumVersion,
      cdpChromiumVersion,
      executableSHA256,
      js: observed.js,
      navigation: navigationHeaders,
      subresource: { modern: observed.modern, legacy: observed.legacy },
      coherent,
    };
    if (!coherent) process.exitCode = 1;
  } finally {
    pageSocket.close();
  }
  // The profile is disposable, but ask Chromium to flush and quit normally.
  browserSocket.send(JSON.stringify({ id: 1, method: 'Browser.close' }));
  await waitForExit(child, 10_000);
} catch (error) {
  console.error(`Device Memory control failed: ${error.name}`);
  process.exitCode = 1;
} finally {
  browserSocket?.close();
  if (child && child.exitCode === null && child.signalCode === null) {
    child.kill('SIGTERM');
    if (!await waitForExit(child, 5_000)) child.kill('SIGKILL');
  }
  const parentExited = !child || startupFailed || await waitForExit(child, 3_000);
  try {
    cleanupSucceeded = parentExited && (!child || await waitForFixtureExit(3_000));
  } catch {
    cleanupSucceeded = false;
  }
  await new Promise(resolve => server.close(resolve));
  if (cleanupSucceeded) fs.rmSync(profile, { recursive: true, force: true });
  else {
    console.error('Own browser shutdown not confirmed; synthetic fixture preserved.');
    process.exitCode = 1;
  }
}
if (observedReport && cleanupSucceeded) {
  console.log(JSON.stringify({ ...observedReport, status: process.exitCode ? 'failed' : 'verified',
    parentExitVerified: true, ownedFixtureProcessCount: 0,
    cleanupScope: 'dedicated-spawn-group-and-exact-synthetic-user-data-root' }));
}
