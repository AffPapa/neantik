// One new capability observation per issued cohort. No old projection suite,
// native build, ordinary profiles, OS networking settings or Keychain access.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {CompatibilityPipe} from '../runtime-compatibility/compat-pipe.mjs';
import {cleanupWithServer} from '../runtime-compatibility/semantics.mjs';
import {verifyMachOClosure} from '../runtime-platform/fixtures/font-runtime-closure.mjs';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';
import {COHORTS, verifyProbe} from './verify.mjs';

const [runtime, bindingFile, output, seedText] = process.argv.slice(2);
assert([runtime, bindingFile, output].every(p => p && path.isAbsolute(p)));
assert.equal(fs.realpathSync(runtime), runtime);
const seed = Number(seedText), cohort = COHORTS.find(c => c.seed === seed); assert(cohort);
const here = path.dirname(fileURLToPath(import.meta.url)), project = path.resolve(here, '../..');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex'), digest = file => sha(fs.readFileSync(file));
fs.mkdirSync(output, {mode: 0o700});
const save = (name, data) => fs.writeFileSync(path.join(output, name), JSON.stringify(data, null, 2) + '\n', {mode: 0o600, flag: 'wx'});
const binding = JSON.parse(fs.readFileSync(bindingFile));
const sourceNames = ['run-headed.mjs', 'probe.js', 'verify.mjs', '../../runtime/apple-device-tuples.json',
  '../runtime-compatibility/compat-pipe.mjs', '../runtime-compatibility/semantics.mjs',
  '../runtime-platform/fixtures/font-runtime-closure.mjs', '../runtime-platform/fixtures/font-lifecycle-pipe.mjs',
  '../runtime-platform/fixtures/qa-browser-environment.mjs', '../native-qa-readiness.py'];
const sources = Object.fromEntries(sourceNames.map(n => [n, digest(path.join(here, n))]));
const sourceArchive = path.join(output, 'source-inputs'); fs.mkdirSync(sourceArchive, {mode: 0o700});
for (const [name, hash] of Object.entries(sources)) if (!fs.existsSync(path.join(sourceArchive, hash)))
  fs.writeFileSync(path.join(sourceArchive, hash), fs.readFileSync(path.join(here, name)), {mode: 0o600, flag: 'wx'});
const executable = path.join(runtime, 'Contents/MacOS/NeAntik Browser');
assert(/^Contents\/Frameworks\/[^\0]+$/.test(binding.runtimeFrameworkRelativePath) && !binding.runtimeFrameworkRelativePath.split('/').includes('..'));
const framework = path.join(runtime, binding.runtimeFrameworkRelativePath);
const tuple = JSON.parse(fs.readFileSync(path.join(project, 'runtime/apple-device-tuples.json'))).tuples[seed % 11];
assert.equal(tuple.id, cohort.id);
const report = {schemaVersion: 1, status: 'not-run', seed, cohortID: cohort.id, sourceSHA256: sources,
  bindingSHA256: digest(bindingFile), runtimeExecutableSHA256: binding.runtimeExecutableSHA256,
  runtimeFrameworkSHA256: binding.runtimeFrameworkSHA256, machOClosureSHA256: binding.machOClosureSHA256,
  actualBrowser: false, headed: true, scope: 'four issued cohorts;capability and bounded texture/error semantics only',
  releaseQualified: false, hardwareQualified: false, startedAt: new Date().toISOString()};
const until = async (predicate, ms) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (await predicate()) return true; await delay(50); } return false;
};
function inventory() {
  const p = spawnSync('/bin/ps', ['-axo', 'pid=,pgid=,uid=,comm='], {encoding: 'utf8'}); assert.equal(p.status, 0);
  return p.stdout.split('\n').flatMap(line => {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    return m && m[4].startsWith(runtime + '/Contents/') ? [{pid: +m[1], group: +m[2], uid: +m[3]}] : [];
  });
}
function inputsUnchanged() {
  assert.equal(digest(bindingFile), report.bindingSHA256);
  assert.equal(digest(executable), binding.runtimeExecutableSHA256); assert.equal(digest(framework), binding.runtimeFrameworkSHA256);
  for (const [name, hash] of Object.entries(sources)) assert.equal(digest(path.join(here, name)), hash);
}
let child, pipe, profile, custody, log, server, origin, failure, result = null;
const nonce = crypto.randomBytes(16).toString('hex');
try {
  inputsUnchanged(); verifyMachOClosure(runtime, binding.machO);
  assert.equal(spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', runtime], {stdio: 'ignore'}).status, 0);
  assert.equal(inventory().length, 0, 'Selected runtime already running');
  const os = spawnSync('/usr/bin/sw_vers', ['-productVersion'], {encoding: 'utf8'}); assert.equal(os.status, 0);
  assert.equal(os.stdout.trim(), binding.macOS); assert.equal(process.arch, binding.architecture); report.macOS = binding.macOS;
  const ready = spawnSync('/usr/local/bin/python3', ['-B', path.join(project, 'scripts/native-qa-readiness.py'), '--check'], {encoding: 'utf8'});
  report.admission = JSON.parse(ready.stdout);
  assert.equal(ready.status, 0, 'Native admission refused;no warning exception');
  assert(report.admission.eligibleForAttempt && report.admission.memoryPressure === 0 && report.admission.thermalState === 0);
  server = http.createServer(async (req, res) => {
    try {
      res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
      if (req.method === 'POST' && req.url === '/result') {
        assert.equal(req.headers.origin, origin); let raw = '';
        for await (const part of req) { raw += part; assert(raw.length <= 32768); }
        const value = JSON.parse(raw); assert.equal(value.nonce, nonce); assert.equal(result, null);
        result = value; res.end('ok'); return;
      }
      assert.equal(req.method, 'GET');
      if (req.url === '/probe.js') { res.setHeader('Content-Type', 'text/javascript'); res.end(fs.readFileSync(path.join(here, 'probe.js'))); return; }
      assert.equal(req.url, '/media?nonce=' + nonce); res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.end(`<!doctype html><html data-nonce="${nonce}"><title>Own cohort ${cohort.id}</title><body style="background:#111;color:white">Own GPU capabilities test<script src="/probe.js"></script></body></html>`);
    } catch { if (!res.headersSent) res.writeHead(400); res.end(); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  origin = 'http://127.0.0.1:' + server.address().port;
  profile = fs.mkdtempSync('/private/tmp/neantik-cohort-capabilities.'); fs.chmodSync(profile, 0o700); custody = fs.lstatSync(profile);
  report.profileRootSHA256 = sha(profile); report.profileCustody = {inode: custody.ino, device: custody.dev, uid: custody.uid, birthtimeMs: custody.birthtimeMs};
  const flags = [`--user-data-dir=${profile}`, '--use-mock-keychain', '--no-first-run', '--no-default-browser-check', '--new-window',
    '--remote-debugging-pipe', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-quic',
    '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=127.0.0.1;localhost',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', 'about:blank'];
  const env = {...browserFixtureEnvironment(), NEANTIK_PROFILE_SEED: String(seed)};
  report.launchArguments = flags.map(f => f.startsWith('--user-data-dir=') ? '--user-data-dir=<own temporary root>' : f);
  log = fs.openSync(path.join(output, 'runtime-private.log'), 'wx', 0o600);
  child = spawn(executable, flags, {env, stdio: ['ignore', 'ignore', log, 'pipe', 'pipe'], detached: true});
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
  report.browserPID = child.pid; report.actualBrowser = true;
  pipe = new CompatibilityPipe(child.stdio[3], child.stdio[4], origin, nonce);
  assert.equal((await pipe.command('Browser.getVersion')).product.split('/').at(-1), binding.runtimeVersion);
  const target = await pipe.command('Target.createTarget', {url: 'about:blank'});
  const {sessionId} = await pipe.command('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await pipe.command('Page.enable', {}, sessionId);
  const nav = await pipe.command('Page.navigate', {url: `${origin}/media?nonce=${nonce}`}, sessionId); assert(!nav.errorText);
  assert(await until(() => result !== null, 20000), 'Own capability observation timed out');
  save('probe.json', result); report.probeSHA256 = digest(path.join(output, 'probe.json'));
  report.verdict = verifyProbe(result, tuple); report.status = 'observed-scoped-capabilities';
} catch (error) { failure = error; report.status = 'failed'; report.failure = {kind: error.name, message: String(error.message).slice(0, 300)}; }
finally {
  try {
    await cleanupWithServer(async () => {
      if (pipe && child?.exitCode === null) await pipe.command('Browser.close').catch(() => {});
      const exited = () => !child || child.exitCode !== null || child.signalCode !== null;
      const graceful = await until(exited, 7000);
      report.closeObservation = {graceful, browserExit: child?.exitCode ?? null, browserSignal: child?.signalCode ?? null};
      if (!graceful) child?.kill('SIGTERM'); await until(exited, 3000); pipe?.close(); if (log !== undefined) fs.closeSync(log);
      await until(() => inventory().length === 0, 3000);
      if (inventory().length && child) {
        assert(inventory().every(p => p.group === child.pid && p.uid === process.getuid()));
        try { process.kill(-child.pid, 'SIGTERM'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
      }
      assert(await until(() => inventory().length === 0, 5000), 'Own processes remain');
      if (profile) {
        const info = fs.lstatSync(profile);
        assert(info.isDirectory() && !info.isSymbolicLink() && info.uid === process.getuid() && info.ino === custody.ino && info.dev === custody.dev);
        fs.rmSync(profile, {recursive: true});
      }
      report.cleanup = {processesRemaining: inventory().length, profileRemoved: !!profile, graceful, browserExit: child?.exitCode ?? null};
      if (child) assert(graceful && child.exitCode === 0 && child.signalCode === null, 'Browser did not exit normally');
      inputsUnchanged();
    }, async () => { if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); } });
  } catch (error) { failure ??= error; report.status = 'failed'; report.cleanupFailure = {kind: error.name, message: String(error.message).slice(0, 300)}; }
  report.finishedAt = new Date().toISOString(); save('observations.json', report);
  console.log(JSON.stringify({status: report.status, cohortID: cohort.id, actualBrowser: report.actualBrowser, verdict: report.verdict, cleanup: report.cleanup, releaseQualified: false}));
}
if (failure) process.exitCode = 1;
