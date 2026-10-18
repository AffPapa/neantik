// MSE operations on one exact public runtime,in an owned root.
// No installed app replacement, profile import, arbitrary JS/CDP or secrets.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {CompatibilityPipe} from '../runtime-compatibility/compat-pipe.mjs';
import {assess} from './verify.mjs';
import {cleanupWithServer} from '../runtime-compatibility/semantics.mjs';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';

const here = path.dirname(fileURLToPath(import.meta.url)), project = path.resolve(here, '../..');

const [app, releaseFile, fixtures, out, mode] = process.argv.slice(2);
assert([app, releaseFile, fixtures, out].every(p => p && path.isAbsolute(p)));
assert(['configured', 'unconfigured'].includes(mode));
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const digest = file => sha(fs.readFileSync(file));
const save = (name, data) => fs.writeFileSync(path.join(out, name), JSON.stringify(data, null, 2) + '\n', {mode: 0o600, flag: 'wx'});
assert(!fs.existsSync(out)); fs.mkdirSync(out, {mode: 0o700});
const report = {schemaVersion: 1, status: 'not-run', scope: 'raw headed exact published runtime MSE operations;not manager/WebKit/DRM/all codec profiles',
  mode, actualBrowser: false, headed: true, releaseQualified: false, startedAt: new Date().toISOString()};
const until = async (predicate, ms) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (await predicate()) return true; await delay(50); }
  return false;
};
function inventory(runtime) {
  const p = spawnSync('/bin/ps', ['-axo', 'pid=,pgid=,uid=,comm='], {encoding: 'utf8'});
  assert.equal(p.status, 0);
  return p.stdout.split('\n').flatMap(line => {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    return m && m[4].startsWith(runtime + '/Contents/') ? [{pid: +m[1], pgid: +m[2], uid: +m[3]}] : [];
  });
}
let runtime, child, pipe, profile, identity, log, server, origin, failure;
try {
  const release = JSON.parse(fs.readFileSync(releaseFile));
  const version = release.runtime.chromiumVersion;
  runtime = path.join(app, 'Contents/Resources/NeAntik Browser.app');
  const executable = path.join(runtime, 'Contents/MacOS/NeAntik Browser');
  const framework = path.join(runtime, `Contents/Frameworks/NeAntik Browser Framework.framework/Versions/${version}/NeAntik Browser Framework`);
  assert.equal(digest(executable), release.runtime.executableSHA256);
  assert.equal(digest(framework), release.runtime.frameworkSHA256);
  assert.equal(digest(path.join(app, 'Contents/MacOS/NeAntik')), release.managerSHA256);
  assert.equal(spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', runtime], {stdio: 'ignore'}).status, 0);
  assert.equal(inventory(runtime).length, 0, 'Exact runtime already running; no shared process custody');
  const manifest = JSON.parse(fs.readFileSync(path.join(fixtures, 'manifest.json')));
  assert.equal(manifest.schemaVersion, 1);
  const assets = new Map();
  for (const [name, expected] of Object.entries(manifest.files)) {
    assert(/^[a-z0-9.-]+$/.test(name));
    const file = path.join(fixtures, name), info = fs.lstatSync(file);
    assert(info.isFile() && !info.isSymbolicLink() && info.size <= 1024 * 1024);
    const raw = fs.readFileSync(file); assert.equal(raw.length, expected.size); assert.equal(sha(raw), expected.sha256);
    assets.set('/' + name, raw);
  }
  const probe = fs.readFileSync(path.join(here, 'probe.js'));
  report.inputs = {releaseReportSHA256: digest(releaseFile), manifestSHA256: digest(path.join(fixtures, 'manifest.json')),
    source: Object.fromEntries(['run-headed.mjs', 'probe.js', 'verify.mjs', 'create-fixtures.py', '../runtime-compatibility/compat-pipe.mjs', '../runtime-compatibility/semantics.mjs',
      '../runtime-platform/fixtures/font-lifecycle-pipe.mjs', '../runtime-platform/fixtures/qa-browser-environment.mjs',
      '../runtime-platform/fixtures/vector-semantics/verify.py', '../native-qa-readiness.py'].map(name => [name, digest(path.join(here, name))]))};
  const sourceArchive = path.join(out, 'source-inputs'); fs.mkdirSync(sourceArchive, {mode: 0o700});
  for (const [name, hash] of Object.entries(report.inputs.source)) {
    const destination = path.join(sourceArchive, hash);
    if (!fs.existsSync(destination)) fs.writeFileSync(destination, fs.readFileSync(path.join(here, name)), {mode: 0o600, flag: 'wx'});
  }
  report.runtime = {version, executableSHA256: release.runtime.executableSHA256, frameworkSHA256: release.runtime.frameworkSHA256};
  report.environment = {architecture: process.arch, macOS: spawnSync('/usr/bin/sw_vers', ['-productVersion'], {encoding: 'utf8'}).stdout.trim()};
  const nonce = crypto.randomBytes(16).toString('hex'); let result = null; const served = [];
  server = http.createServer(async (req, res) => {
    try {
      res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
      const url = new URL(req.url, origin);
      if (req.method === 'POST' && url.pathname === '/result') {
        assert.equal(req.headers.origin, origin); let raw = '';
        for await (const part of req) { raw += part; assert(raw.length <= 32768); }
        const data = JSON.parse(raw); assert.equal(data.nonce, nonce); assert.equal(result, null);
        result = data; res.end('ok'); return;
      }
      assert.equal(req.method, 'GET');
      if (url.pathname === '/manifest.json') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(manifest)); return; }
      if (url.pathname === '/probe.js') { res.setHeader('Content-Type', 'text/javascript'); res.end(probe); return; }
      if (assets.has(url.pathname)) {
        const raw = assets.get(url.pathname); served.push({file: url.pathname.slice(1), sha256: sha(raw), bytes: raw.length});
        const type = url.pathname.endsWith('.pdf') ? 'application/pdf' : url.pathname.endsWith('.webm') ? (url.pathname.includes('solid') ? 'video/webm' : 'audio/webm') : url.pathname.endsWith('.mp4') ? 'video/mp4' : url.pathname.endsWith('.m4a') ? 'audio/mp4' : 'audio/wav';
        res.setHeader('Content-Type', type); res.setHeader('Content-Length', raw.length); res.end(raw); return;
      }
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      assert.equal(url.searchParams.get('nonce'), nonce);
      if (url.pathname === '/media') {
        res.end(`<html data-nonce="${nonce}"><body style="background:#111;color:white"><p id="status">Own compatibility QA</p><script src="/probe.js"></script></body></html>`); return;
      }
      assert(['/colours', '/blank'].includes(url.pathname));
      const file = url.pathname === '/colours' ? 'colours.pdf' : 'blank.pdf';
      res.end(`<html><body style="margin:0;background:#111"><embed style="position:absolute;inset:0;width:256px;height:256px" type="application/pdf" src="/${file}#toolbar=0&zoom=100"></body></html>`);
    } catch { if (!res.headersSent) res.writeHead(400); res.end(); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  origin = 'http://127.0.0.1:' + server.address().port;
  const ready = spawnSync('python3', ['-B', path.join(project, 'scripts/native-qa-readiness.py'), '--check'], {encoding: 'utf8'});
  report.admission = JSON.parse(ready.stdout);
  assert(ready.status === 0 && report.admission.eligibleForAttempt && report.admission.memoryPressure === 1, 'Native resource admission refused; no warning exception');
  profile = fs.mkdtempSync('/private/tmp/neantik-compatibility.'); fs.chmodSync(profile, 0o700); identity = fs.lstatSync(profile);
  log = fs.openSync(path.join(out, 'runtime-private.log'), 'wx', 0o600);
  const flags = [`--user-data-dir=${profile}`, '--use-mock-keychain', '--no-first-run', '--no-default-browser-check', '--new-window',
    '--remote-debugging-pipe', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-quic',
    '--autoplay-policy=no-user-gesture-required', '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=127.0.0.1;localhost',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', 'about:blank'];
  const env = browserFixtureEnvironment(); if (mode === 'configured') env.NEANTIK_PROFILE_SEED = '21';
  report.launchArguments = flags.map(f => f.startsWith('--user-data-dir=') ? '--user-data-dir=<owned temporary root>' : f);
  report.profileRootSHA256 = sha(profile); report.profileCustody = {inode:identity.ino,device:identity.dev,uid:identity.uid,birthtimeMs:identity.birthtimeMs}; report.seed = mode === 'configured' ? 21 : null;
  child = spawn(executable, flags, {env, stdio: ['ignore', 'ignore', log, 'pipe', 'pipe'], detached: true});
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
  report.actualBrowser = true; report.browserPID = child.pid;
  pipe = new CompatibilityPipe(child.stdio[3], child.stdio[4], origin, nonce);
  assert.equal((await pipe.command('Browser.getVersion')).product.split('/').at(-1), version);
  const target = await pipe.command('Target.createTarget', {url: 'about:blank'});
  const {sessionId} = await pipe.command('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await pipe.command('Page.enable', {}, sessionId);
  const navigate = async page => {
    const result = await pipe.command('Page.navigate', {url: `${origin}/${page}?nonce=${nonce}`}, sessionId);
    assert(!result.errorText);
  };
  await navigate('media'); assert(await until(() => result !== null, 30000), 'MSE observation timeout');
  save('media.json', result); report.mse = assess(result, manifest); report.served = served;
  assert.equal(report.mse.status, 'passed-scoped-mse-operations', 'MSE operation/control failed');
  for (const c of manifest.cases) for (const file of c.files) assert(served.some(e => e.file === file && e.sha256 === manifest.files[file].sha256));
  report.status = 'observed-scoped-mse';
} catch (error) { failure = error; report.status = 'failed'; report.failure = {kind: error.name, message: String(error.message).slice(0, 300)}; }
finally {
  try {
    await cleanupWithServer(async () => {
    if (pipe && child?.exitCode === null) await pipe.command('Browser.close').catch(() => {});
    const exited = () => !child || child.exitCode !== null || child.signalCode !== null;
    const graceful = await until(exited, 7000);
    report.closeObservation = {graceful, browserExit:child?.exitCode??null, browserSignal:child?.signalCode??null};
    if (!graceful) child?.kill('SIGTERM'); await until(exited, 3000); pipe?.close(); if (log !== undefined) fs.closeSync(log);
    // Crashpad/helpers can outlive main-process exit briefly in a different
    // group. Observe natural drain first;never signal an unbound process.
    if (runtime) await until(() => inventory(runtime).length === 0, 3000);
    if (runtime && inventory(runtime).length && child) {
      assert(inventory(runtime).every(p => p.pgid === child.pid && p.uid === process.getuid()));
      try { process.kill(-child.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      assert(await until(() => inventory(runtime).length === 0, 5000), 'Owned processes remain');
    }
    if (profile) {
      const info = fs.lstatSync(profile); assert(info.ino === identity.ino && info.dev === identity.dev && info.uid === process.getuid() && info.isDirectory() && !info.isSymbolicLink());
      fs.rmSync(profile, {recursive: true});
    }
    report.cleanup = {ownedProcessesRemaining: runtime ? inventory(runtime).length : 0, ownedProfileRemoved: !!profile, graceful, browserExit: child?.exitCode ?? null};
    if (child) assert(graceful && child.exitCode === 0, 'Browser did not close gracefully');
    if (report.inputs) {
      for (const [name, hash] of Object.entries(report.inputs.source)) assert.equal(digest(path.join(here, name)), hash);
      assert.equal(digest(releaseFile), report.inputs.releaseReportSHA256);
      assert.equal(digest(path.join(fixtures, 'manifest.json')), report.inputs.manifestSHA256);
      for (const [name, expected] of Object.entries(JSON.parse(fs.readFileSync(path.join(fixtures, 'manifest.json'))).files)) {
        assert.equal(digest(path.join(fixtures, name)), expected.sha256);
      }
      assert.equal(digest(path.join(runtime, 'Contents/MacOS/NeAntik Browser')), report.runtime.executableSHA256);
      assert.equal(digest(path.join(runtime, `Contents/Frameworks/NeAntik Browser Framework.framework/Versions/${report.runtime.version}/NeAntik Browser Framework`)), report.runtime.frameworkSHA256);
    }
    }, async () => {
      if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    });
  } catch (error) { failure ??= error; report.status = 'failed'; report.cleanupFailure = {kind: error.name, message: String(error.message).slice(0, 300)}; }
  report.finishedAt = new Date().toISOString(); save('observations.json', report);
  console.log(JSON.stringify({status: report.status, actualBrowser: report.actualBrowser, mse: report.mse, cleanup: report.cleanup, releaseQualified: false}));
}
if (failure) process.exitCode = 1;
