// New WS/WSS behavior only, on an exact already-published runtime.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {WebSocketRouteFixture} from './websocket-fixture.mjs';
import {verifyWebSocketRoute} from './websocket-route-verify.mjs';
import {CompatibilityPipe} from '../runtime-compatibility/compat-pipe.mjs';
import {verifyMachOClosure} from '../runtime-platform/fixtures/font-runtime-closure.mjs';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';

const [runtime, bindingFile, output, mode] = process.argv.slice(2);
assert([runtime, bindingFile, output].every(p => p && path.isAbsolute(p)));
assert(['protected', 'bypass-control'].includes(mode)); assert.equal(fs.realpathSync(runtime), runtime);
const here = path.dirname(fileURLToPath(import.meta.url)), project = path.resolve(here, '../..');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex'), digest = file => sha(fs.readFileSync(file));
fs.mkdirSync(output, {mode: 0o700});
const binding = JSON.parse(fs.readFileSync(bindingFile));
const executable = path.join(runtime, 'Contents/MacOS/NeAntik Browser');
assert(/^Contents\/Frameworks\/[^\0]+$/.test(binding.runtimeFrameworkRelativePath) && !binding.runtimeFrameworkRelativePath.split('/').includes('..'));
const framework = path.join(runtime, binding.runtimeFrameworkRelativePath);
const sourceNames = ['run-websocket-route.mjs', 'websocket-fixture.mjs', 'websocket-route-probe.js', 'websocket-route-verify.mjs',
  '../runtime-compatibility/compat-pipe.mjs', '../runtime-platform/fixtures/font-lifecycle-pipe.mjs',
  '../runtime-platform/fixtures/font-runtime-closure.mjs', '../runtime-platform/fixtures/qa-browser-environment.mjs', '../native-qa-readiness.py'];
const sourceSHA256 = Object.fromEntries(sourceNames.map(name => [name, digest(path.join(here, name))]));
fs.mkdirSync(path.join(output, 'source-inputs'), {mode: 0o700});
for (const [name, hash] of Object.entries(sourceSHA256)) {
  const to = path.join(output, 'source-inputs', hash);
  if (!fs.existsSync(to)) fs.writeFileSync(to, fs.readFileSync(path.join(here, name)), {mode: 0o600, flag: 'wx'});
}
const save = (name, value) => fs.writeFileSync(path.join(output, name), JSON.stringify(value, null, 2) + '\n', {mode: 0o600, flag: 'wx'});
const report = {schemaVersion: 1, status: 'not-run', mode, actualBrowser: false, headed: true,
  sourceSHA256, bindingSHA256: digest(bindingFile), runtimeExecutableSHA256: binding.runtimeExecutableSHA256,
  runtimeFrameworkSHA256: binding.runtimeFrameworkSHA256, machOClosureSHA256: binding.machOClosureSHA256,
  releaseQualified: false, managerQualified: false, startedAt: new Date().toISOString()};
const until = async (test, ms) => { const end = Date.now() + ms; while (Date.now() < end) { if (await test()) return true; await delay(50); } return false; };
function inventory() {
  const p = spawnSync('/bin/ps', ['-axo', 'pid=,pgid=,uid=,comm='], {encoding: 'utf8'}); assert.equal(p.status, 0);
  return p.stdout.split('\n').flatMap(line => {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    return m && m[4].startsWith(runtime + '/Contents/') ? [{pid: +m[1], group: +m[2], uid: +m[3]}] : [];
  });
}
function unchanged() {
  assert.equal(digest(bindingFile), report.bindingSHA256); assert.equal(digest(executable), binding.runtimeExecutableSHA256);
  assert.equal(digest(framework), binding.runtimeFrameworkSHA256);
  for (const [name, hash] of Object.entries(sourceSHA256)) assert.equal(digest(path.join(here, name)), hash);
}
let child, pipe, root, custody, log, control, fixture, failure, result = null;
let forcedCleanup = false;
const nonce = crypto.randomBytes(16).toString('hex'); let origin;
const controlSockets = new Set();
try {
  unchanged(); verifyMachOClosure(runtime, binding.machO);
  assert.equal(spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', runtime], {stdio: 'ignore'}).status, 0);
  assert.equal(inventory().length, 0, 'Selected runtime already running');
  assert.equal(process.arch, binding.architecture);
  assert.equal(spawnSync('/usr/bin/sw_vers', ['-productVersion'], {encoding: 'utf8'}).stdout.trim(), binding.macOS);
  report.macOS = binding.macOS; report.architecture = process.arch;
  const ready = spawnSync('/usr/local/bin/python3', ['-B', path.join(project, 'scripts/native-qa-readiness.py'), '--check'], {encoding: 'utf8'});
  report.admission = JSON.parse(ready.stdout);
  assert(ready.status === 0 && report.admission.eligibleForAttempt && report.admission.memoryPressure === 0 && report.admission.thermalState === 0, 'Native admission refused;no warning exception');
  root = fs.mkdtempSync('/private/tmp/neantik-websocket-route.'); fs.chmodSync(root, 0o700); custody = fs.lstatSync(root);
  report.ownedRootSHA256 = sha(root); report.rootCustody = {inode: custody.ino, device: custody.dev, uid: custody.uid, birthtimeMs: custody.birthtimeMs};
  const keyFile = path.join(root, 'own-qa-key.pem'), certFile = path.join(root, 'own-qa-cert.pem');
  const generated = spawnSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyFile, '-out', certFile,
    '-subj', '/CN=localhost', '-days', '1'], {stdio: 'ignore'}); assert.equal(generated.status, 0); fs.chmodSync(keyFile, 0o600);
  const cert = fs.readFileSync(certFile), key = fs.readFileSync(keyFile);
  const publicKey = new crypto.X509Certificate(cert).publicKey.export({type: 'spki', format: 'der'});
  const spki = crypto.createHash('sha256').update(publicKey).digest('base64');
  report.tls = {ownShortLivedCertificate: true, exactSPKIExceptionOnly: true, systemTrustChanged: false};
  fixture = await new WebSocketRouteFixture(nonce, {key, cert}).start();
  const probe = fs.readFileSync(path.join(here, 'websocket-route-probe.js'));
  let initialRead = false;
  control = http.createServer(async (req, res) => {
    try {
      res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
      const url = new URL(req.url, origin);
      if (url.pathname === '/result') {
        assert.equal(req.method, 'POST'); assert.equal(req.headers.origin, origin); assert.equal(result, null);
        let raw = ''; for await (const part of req) { raw += part; assert(raw.length <= 32768); }
        const value = JSON.parse(raw); assert.equal(value.nonce, nonce); assert.equal(value.mode, mode); result = value; res.end('ok'); return;
      }
      assert.equal(req.method, 'GET');
      if (url.pathname === '/probe.js') { res.setHeader('Content-Type', 'text/javascript'); res.end(probe); return; }
      assert.equal(url.searchParams.get('nonce'), nonce);
      if (url.pathname === '/control') {
        const phase = url.searchParams.get('phase'); let urls;
        if (phase === 'initial') { assert(!initialRead && fixture.phase === 'initial'); initialRead = true; urls = fixture.urls(phase); }
        else { assert(initialRead); urls = await fixture.transition(phase); }
        res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(urls)); return;
      }
      assert.equal(url.pathname, '/media'); res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.end(`<!doctype html><html data-nonce="${nonce}" data-mode="${mode}"><title>Own WS/WSS ${mode}</title><body style="background:#111;color:#fff">Own WS/WSS route test<script src="/probe.js"></script></body></html>`);
    } catch { if (!res.headersSent) res.writeHead(400); res.end(); }
  });
  control.on('connection', socket => { controlSockets.add(socket); socket.on('error', () => {}); socket.once('close', () => controlSockets.delete(socket)); });
  await new Promise((resolve, reject) => { control.once('error', reject); control.listen(0, '127.0.0.1', resolve); });
  origin = 'http://127.0.0.1:' + control.address().port; fixture.origin = origin;
  const bypass = ['<-loopback>', '127.0.0.1:' + control.address().port];
  if (mode === 'bypass-control') for (const p of ['ws', 'wss']) bypass.push('127.0.0.1:' + fixture[p].address().port);
  const flags = ['--user-data-dir=' + path.join(root, 'BrowserData'), '--use-mock-keychain', '--no-first-run', '--no-default-browser-check', '--new-window',
    '--remote-debugging-pipe', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-quic',
    '--proxy-server=http://127.0.0.1:' + fixture.proxyPort, '--proxy-bypass-list=' + bypass.join(';'),
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', '--ignore-certificate-errors-spki-list=' + spki, 'about:blank'];
  report.launchArguments = flags.map(f => f.startsWith('--user-data-dir=') ? '--user-data-dir=<owned temporary root>/BrowserData' : f);
  log = fs.openSync(path.join(output, 'runtime-private.log'), 'wx', 0o600);
  child = spawn(executable, flags, {env: {...browserFixtureEnvironment(), NEANTIK_PROFILE_SEED: '11'}, detached: true, stdio: ['ignore', 'ignore', log, 'pipe', 'pipe']});
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
  report.browserPID = child.pid; report.actualBrowser = true;
  pipe = new CompatibilityPipe(child.stdio[3], child.stdio[4], origin, nonce);
  assert.equal((await pipe.command('Browser.getVersion')).product.split('/').at(-1), binding.runtimeVersion);
  const target = await pipe.command('Target.createTarget', {url: 'about:blank'});
  const {sessionId} = await pipe.command('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await pipe.command('Page.enable', {}, sessionId);
  assert(!(await pipe.command('Page.navigate', {url: `${origin}/media?nonce=${nonce}`}, sessionId)).errorText);
  assert(await until(() => result !== null, 30000), 'Own WS/WSS result timed out');
  save('probe.json', result); report.probeSHA256 = digest(path.join(output, 'probe.json')); report.status = 'observed-scoped-websocket-route';
} catch (error) { failure = error; report.status = 'failed'; report.failure = {kind: error.name, message: String(error.message).slice(0, 240)}; }
finally {
  try {
    if (pipe && child?.exitCode === null) await pipe.command('Browser.close').catch(() => {});
    const exited = () => !child || child.exitCode !== null || child.signalCode !== null;
    const graceful = await until(exited, 7000); report.closeObservation = {graceful, browserExit: child?.exitCode ?? null, browserSignal: child?.signalCode ?? null};
    if (!graceful) { forcedCleanup = true; child?.kill('SIGTERM'); await until(exited, 3000); }
    pipe?.close(); if (log !== undefined) fs.closeSync(log);
    await until(() => inventory().length === 0, 3000);
    if (inventory().length && child) {
      assert(inventory().every(p => p.group === child.pid && p.uid === process.getuid()));
      forcedCleanup = true;
      try { process.kill(-child.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
    assert(await until(() => inventory().length === 0, 5000), 'Own browser processes remain');
    report.cleanup = {processesRemaining: 0, rootRemoved: false, graceful, forcedCleanup, browserExit: child?.exitCode ?? null};
    if (child) assert(graceful && child.exitCode === 0 && child.signalCode === null, 'Non-normal browser exit');
    unchanged();
  } catch (error) { failure ??= error; report.status = 'failed'; report.cleanupFailure = {kind: error.name}; }
  finally {
    try {
      // Attempt both server cleanups even if the other rejects. Data/key
      // retirement remains independent of assertions about the test verdict.
      const stopped = await Promise.allSettled([
        (async () => { if (fixture) report.fixtureCleanup = await fixture.close(); })(),
        (async () => { for (const socket of controlSockets) socket.destroy(); if (control?.listening) await new Promise(resolve => control.close(resolve)); })()
      ]);
      report.controlListenerClosed = !control?.listening;
      if (fixture) { report.events = fixture.events; report.transitions = fixture.transitions; }
      if (root) {
        assert.equal(inventory().length, 0); const info = fs.lstatSync(root);
        assert(info.isDirectory() && !info.isSymbolicLink() && info.ino === custody.ino && info.dev === custody.dev && info.uid === process.getuid());
        fs.rmSync(root, {recursive: true}); report.ownTLSKeyRemoved = !fs.existsSync(root); report.cleanup ??= {}; report.cleanup.rootRemoved = true;
      }
      assert(stopped.every(v => v.status === 'fulfilled'), 'Own fixture cleanup failed');
      if (fixture) assert(report.fixtureCleanup.listenersClosed && report.fixtureCleanup.socketsRemaining === 0);
      if (result && fixture) { report.verdict = verifyWebSocketRoute(result, fixture.events, mode, fixture.transitions); assert.equal(report.verdict.issues.length, 0, 'WS/WSS behavior verification failed'); }
    } catch (error) { failure ??= error; report.status = 'failed'; report.finalizationFailure = {kind: error.name, message: String(error.message).slice(0, 100)}; }
    report.finishedAt = new Date().toISOString(); save('observations.json', report);
    console.log(JSON.stringify({status: report.status, actualBrowser: report.actualBrowser, mode, verdict: report.verdict, cleanup: report.cleanup, fixtureCleanup: report.fixtureCleanup, ownTLSKeyRemoved: report.ownTLSKeyRemoved}));
  }
}
if (failure) process.exitCode = 1;
