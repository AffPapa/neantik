// New same-cohort seed/storage scope. Four bounded sessions,including one
// intentional wrong-root negative. This does not exercise the manager UI.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {CompatibilityPipe} from '../runtime-compatibility/compat-pipe.mjs';
import {verifyMachOClosure} from '../runtime-platform/fixtures/font-runtime-closure.mjs';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';
import {ISOLATION_PHASES, verifyIsolationCase, verifyIsolationSuite} from './isolation-verify.mjs';

const [runtime, bindingFile, output] = process.argv.slice(2);
assert([runtime, bindingFile, output].every(p => p && path.isAbsolute(p))); assert.equal(fs.realpathSync(runtime), runtime);
const here = path.dirname(fileURLToPath(import.meta.url)), project = path.resolve(here, '../..');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex'), digest = file => sha(fs.readFileSync(file));
fs.mkdirSync(output, {mode: 0o700});
const save = (name, data) => fs.writeFileSync(path.join(output, name), JSON.stringify(data, null, 2) + '\n', {mode: 0o600, flag: 'wx'});
const binding = {...JSON.parse(fs.readFileSync(bindingFile)), bindingSHA256: digest(bindingFile)};
const executable = path.join(runtime, 'Contents/MacOS/NeAntik Browser');
assert(/^Contents\/Frameworks\/[^\0]+$/.test(binding.runtimeFrameworkRelativePath) && !binding.runtimeFrameworkRelativePath.split('/').includes('..'));
const framework = path.join(runtime, binding.runtimeFrameworkRelativePath);
const names = ['run-isolation.mjs', 'isolation-probe.js', 'isolation-verify.mjs', '../../runtime/apple-device-tuples.json',
  '../runtime-compatibility/compat-pipe.mjs', '../runtime-platform/fixtures/font-runtime-closure.mjs',
  '../runtime-platform/fixtures/font-lifecycle-pipe.mjs', '../runtime-platform/fixtures/qa-browser-environment.mjs', '../native-qa-readiness.py'];
const sources = Object.fromEntries(names.map(n => [n, digest(path.join(here, n))]));
const archived = path.join(output, 'source-inputs'); fs.mkdirSync(archived, {mode: 0o700});
for (const [name, hash] of Object.entries(sources)) if (!fs.existsSync(path.join(archived, hash)))
  fs.writeFileSync(path.join(archived, hash), fs.readFileSync(path.join(here, name)), {mode: 0o600, flag: 'wx'});
const tuples = JSON.parse(fs.readFileSync(path.join(project, 'runtime/apple-device-tuples.json'))).tuples;
assert.equal(tuples.length, 11); const tuple = tuples[0]; assert.equal(tuple.id, 'macbook-air-m1');
const markers = {A: crypto.randomBytes(16).toString('hex'), B: crypto.randomBytes(16).toString('hex')}; assert.notEqual(markers.A, markers.B);
const report = {schemaVersion: 1, status: 'not-run', rows: [], releaseQualified: false, managerQualified: false,
  binding, sourceSHA256: sources, markers, startedAt: new Date().toISOString()};
let ownRoot, rootStat, server, origin, current, result, failure;
const until = async (predicate, ms) => { const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (await predicate()) return true; await delay(50); } return false; };
function ownedProcesses() {
  const p = spawnSync('/bin/ps', ['-axo', 'pid=,pgid=,uid=,comm='], {encoding: 'utf8'}); assert.equal(p.status, 0);
  return p.stdout.split('\n').flatMap(line => { const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    return m && m[4].startsWith(runtime + '/Contents/') ? [{pid: +m[1], group: +m[2], uid: +m[3]}] : []; });
}
function inputsUnchanged() {
  assert.equal(digest(bindingFile), binding.bindingSHA256); assert.equal(digest(executable), binding.runtimeExecutableSHA256);
  assert.equal(digest(framework), binding.runtimeFrameworkSHA256);
  for (const [name, hash] of Object.entries(sources)) assert.equal(digest(path.join(here, name)), hash);
}
const verifyDirectory = (directory, prior) => {
  const now = fs.lstatSync(directory); assert(now.isDirectory() && !now.isSymbolicLink() && now.uid === process.getuid());
  for (const field of ['ino', 'dev', 'birthtimeMs']) assert.equal(now[field], prior[field]);
};
async function run(spec) {
  const profile = path.join(ownRoot, spec.profile), custody = fs.lstatSync(profile); verifyDirectory(ownRoot, rootStat);
  const row = {id: spec.id, profile: spec.profile, seed: spec.seed, status: 'not-run', actualBrowser: false, headed: true,
    profileRootSHA256: sha(profile), profileCustody: {inode: custody.ino, device: custody.dev, uid: custody.uid, birthtimeMs: custody.birthtimeMs},
    ...Object.fromEntries(['runtimeExecutableSHA256', 'runtimeFrameworkSHA256', 'machOClosureSHA256', 'bindingSHA256', 'macOS'].map(k => [k, binding[k]])),
    sourceSHA256: sources, startedAt: new Date().toISOString()};
  let child, pipe, log, phaseError;
  try {
    inputsUnchanged(); assert.equal(ownedProcesses().length, 0); verifyDirectory(profile, custody);
    const ready = spawnSync('/usr/local/bin/python3', ['-B', path.join(project, 'scripts/native-qa-readiness.py'), '--check'], {encoding: 'utf8'});
    row.admission = JSON.parse(ready.stdout); assert.equal(ready.status, 0, 'Native admission refused;no warning exception');
    assert(row.admission.eligibleForAttempt && row.admission.memoryPressure === 1 && [0, 1].includes(row.admission.thermalState));
    current = {nonce: crypto.randomBytes(16).toString('hex'), spec, row}; result = null;
    const flags = [`--user-data-dir=${profile}`, '--use-mock-keychain', '--no-first-run', '--no-default-browser-check', '--new-window',
      '--remote-debugging-pipe', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-quic',
      '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=127.0.0.1;localhost',
      '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', 'about:blank'];
    row.launchArguments = flags.map(f => f.startsWith('--user-data-dir=') ? '--user-data-dir=<owned A or B>' : f);
    log = fs.openSync(path.join(output, spec.id + '-runtime-private.log'), 'wx', 0o600);
    child = spawn(executable, flags, {env: {...browserFixtureEnvironment(), NEANTIK_PROFILE_SEED: String(spec.seed)},
      stdio: ['ignore', 'ignore', log, 'pipe', 'pipe'], detached: true});
    await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
    row.actualBrowser = true; row.browserPID = child.pid;
    pipe = new CompatibilityPipe(child.stdio[3], child.stdio[4], origin, current.nonce);
    assert.equal((await pipe.command('Browser.getVersion')).product.split('/').at(-1), binding.runtimeVersion);
    const target = await pipe.command('Target.createTarget', {url: 'about:blank'});
    const {sessionId} = await pipe.command('Target.attachToTarget', {targetId: target.targetId, flatten: true});
    await pipe.command('Page.enable', {}, sessionId);
    const nav = await pipe.command('Page.navigate', {url: `${origin}/media?nonce=${current.nonce}`}, sessionId); assert(!nav.errorText);
    assert(await until(() => result !== null, 20000), 'Owned storage probe timed out'); row.probe = result; row.status = 'observed';
  } catch (e) { phaseError = e; row.status = 'failed'; row.failure = {kind: e.name, message: String(e.message).slice(0, 250)}; }
  finally {
    try {
      if (pipe && child?.exitCode === null) await pipe.command('Browser.close').catch(() => {});
      const exited = () => !child || child.exitCode !== null || child.signalCode !== null;
      const graceful = await until(exited, 7000);
      row.closeObservation = {graceful, browserExit: child?.exitCode ?? null, browserSignal: child?.signalCode ?? null, processesRemaining: 0};
      if (!graceful) child?.kill('SIGTERM'); await until(exited, 3000); pipe?.close(); if (log !== undefined) fs.closeSync(log);
      await until(() => ownedProcesses().length === 0, 3000);
      if (ownedProcesses().length && child) {
        assert(ownedProcesses().every(p => p.group === child.pid && p.uid === process.getuid()));
        try { process.kill(-child.pid, 'SIGTERM'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
      }
      assert(await until(() => ownedProcesses().length === 0, 5000)); verifyDirectory(profile, custody);
      row.closeObservation.processesRemaining = ownedProcesses().length;
      if (child) assert(graceful && child.exitCode === 0 && child.signalCode === null);
      inputsUnchanged();
    } catch (e) { phaseError ??= e; row.status = 'failed'; row.cleanupFailure = {kind: e.name, message: String(e.message).slice(0, 250)}; }
    row.finishedAt = new Date().toISOString(); report.rows.push(row); save(spec.id + '.json', row);
  }
  if (phaseError) throw phaseError;
  verifyIsolationCase(row, spec, tuple, markers, binding, sources);
  console.log(JSON.stringify({phase: spec.id, storage: spec.id === 'wrong-root' ? 'intentional reuse detected;write refused' : 'scoped-pass', normalExit: true}));
}
try {
  inputsUnchanged(); verifyMachOClosure(runtime, binding.machO);
  assert.equal(spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', runtime], {stdio: 'ignore'}).status, 0);
  const os = spawnSync('/usr/bin/sw_vers', ['-productVersion'], {encoding: 'utf8'}); assert.equal(os.status, 0);
  assert.equal(os.stdout.trim(), binding.macOS); assert.equal(process.arch, binding.architecture); assert.equal(ownedProcesses().length, 0);
  ownRoot = fs.mkdtempSync('/private/tmp/neantik-cohort-isolation.'); fs.chmodSync(ownRoot, 0o700); rootStat = fs.lstatSync(ownRoot);
  for (const name of ['A', 'B']) fs.mkdirSync(path.join(ownRoot, name), {mode: 0o700});
  report.ownRootSHA256 = sha(ownRoot); report.ownRootCustody = {inode: rootStat.ino, device: rootStat.dev, uid: rootStat.uid, birthtimeMs: rootStat.birthtimeMs};
  server = http.createServer(async (req, res) => {
    try {
      assert(current); res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
      if (req.method === 'POST' && req.url === '/result') {
        assert.equal(req.headers.origin, origin); let raw = '';
        for await (const part of req) { raw += part; assert(raw.length <= 16384); }
        const data = JSON.parse(raw); assert.equal(data.nonce, current.nonce); assert.equal(data.phase, current.spec.id); assert.equal(result, null);
        result = data; res.end('ok'); return;
      }
      assert.equal(req.method, 'GET');
      if (req.url === '/probe.js') { res.setHeader('Content-Type', 'text/javascript'); res.end(fs.readFileSync(path.join(here, 'isolation-probe.js'))); return; }
      if (req.url === '/worker.js') { res.setHeader('Content-Type', 'text/javascript'); res.end("addEventListener('install',e=>e.waitUntil(skipWaiting()));addEventListener('activate',e=>e.waitUntil(clients.claim()));"); return; }
      assert.equal(req.url, '/media?nonce=' + current.nonce);
      current.row.initialHTTPCookie = req.headers.cookie?.split('; ').find(x => x.startsWith('neantik_own_marker='))?.split('=')[1] ?? null;
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.end(`<!doctype html><html data-nonce="${current.nonce}" data-phase="${current.spec.id}" data-marker="${markers[current.spec.profile]}"><title>Own cohort storage ${current.spec.id}</title><body style="background:#111;color:white">Own seed and storage test<script src="/probe.js"></script></body></html>`);
    } catch { if (!res.headersSent) res.writeHead(400); res.end(); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); }); origin = 'http://127.0.0.1:' + server.address().port;
  for (const spec of ISOLATION_PHASES) await run(spec);
  report.status = 'observed';
} catch (error) { failure = error; report.status = 'failed'; report.failure = {kind: error.name, message: String(error.message).slice(0, 250)}; }
finally {
  try {
    if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    assert.equal(ownedProcesses().length, 0);
    if (ownRoot) { verifyDirectory(ownRoot, rootStat); fs.rmSync(ownRoot, {recursive: true}); }
    report.cleanup = {serversClosed: true, processesRemaining: ownedProcesses().length, ownRootRemoved: !!ownRoot};
    inputsUnchanged();
  } catch (e) { failure ??= e; report.status = 'failed'; report.cleanupFailure = {kind: e.name, message: String(e.message).slice(0, 250)}; }
  if (!failure) {
    try { report.verdict = verifyIsolationSuite(report, tuple, markers, binding, sources); }
    catch (e) { failure = e; report.status = 'failed'; report.verificationFailure = {kind: e.name, message: String(e.message).slice(0, 250)}; }
  }
  report.finishedAt = new Date().toISOString(); save('observations.json', report);
  console.log(JSON.stringify({status: report.status, verdict: report.verdict, cleanup: report.cleanup}));
}
if (failure) process.exitCode = 1;
