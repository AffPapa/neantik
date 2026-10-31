// Narrow raw-runtime QA. Own page, profile, sockets and fixed CDP operations.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {SpeechPipe} from './speech-pipe.mjs';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';
import {verifyVoices} from './semantics.mjs';
import {settleOwnedProcesses} from './cleanup.mjs';
import {speechAdmission} from './admission.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, '../..');
const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const [app, releaseFile, out, mode, locale, seedArg] = process.argv.slice(2);
const options = process.argv.slice(8);
assert(options.length === 0 || (options.length === 1 && options[0] === '--approved-warning-stage'));
const approvedWarningStage = options.length === 1;
if (approvedWarningStage) assert(
  (mode === 'configured' && ((locale === 'fr-FR' && seedArg === '20') || (locale === 'en-US' && seedArg === '21'))) ||
  (mode === 'unconfigured' && locale === 'fr-FR' && seedArg === '-'), 'Only the three approved remaining cases');
assert([app, releaseFile, out].every(p => p && path.isAbsolute(p)));
assert(['configured', 'unconfigured'].includes(mode) && ['en-US', 'fr-FR'].includes(locale));
const seed = mode === 'configured' ? Number(seedArg) : null;
assert(mode === 'unconfigured' ? seedArg === '-' : Number.isInteger(seed) && seed >= 11 && seed <= 21);
assert(!fs.existsSync(out)); fs.mkdirSync(out, {mode: 0o700});
const save = (name, value) => fs.writeFileSync(path.join(out, name), JSON.stringify(value, null, 2) + '\n', {mode: 0o600, flag: 'wx'});
const until = async (predicate, ms) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (await predicate()) return true; await delay(50); }
  return false;
};
function inventory(runtime) {
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,pgid=,uid=,comm='], {encoding: 'utf8'});
  assert.equal(result.status, 0, 'Own-process inventory unavailable');
  return result.stdout.split('\n').flatMap(line => {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    return m && m[4].startsWith(runtime + '/Contents/') ? [{pid: +m[1], pgid: +m[2], uid: +m[3]}] : [];
  });
}
const report = {schemaVersion: 1, status: 'not-run', startedAt: new Date().toISOString(),
  scope: 'raw headed exact downloaded runtime; not manager locale plumbing or installed catalog change',
  mode, requestedLocale: locale, seed, actualBrowser: false, headed: true, releaseQualified: false};
let runtime, executable, framework, child, pipe, profile, profileIdentity, log, server, blocker, failure;
let phase = 'preflight';
try {
  const release = JSON.parse(fs.readFileSync(releaseFile));
  runtime = path.join(app, 'Contents/Resources/NeAntik Browser.app');
  executable = path.join(runtime, 'Contents/MacOS/NeAntik Browser');
  framework = path.join(runtime, `Contents/Frameworks/NeAntik Browser Framework.framework/Versions/${release.runtime.chromiumVersion}/NeAntik Browser Framework`);
  assert.equal(digest(executable), release.runtime.executableSHA256);
  assert.equal(digest(framework), release.runtime.frameworkSHA256);
  assert.equal(digest(path.join(app, 'Contents/MacOS/NeAntik')), release.managerSHA256);
  assert.equal(spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], {stdio: 'ignore'}).status, 0, 'Exact app signature');
  assert.equal(inventory(runtime).length, 0, 'Exact runtime already running; no shared custody');
  report.runtime = release.runtime;
  report.publicAppSource = release.sourceCommit;
  report.environment = {architecture: process.arch,
    macOS: spawnSync('/usr/bin/sw_vers', ['-productVersion'], {encoding: 'utf8'}).stdout.trim()};
  const inputs = ['run-headed.mjs', 'probe.mjs', 'semantics.mjs', 'speech-pipe.mjs', 'cleanup.mjs', 'admission.mjs',
    '../runtime-platform/fixtures/font-lifecycle-pipe.mjs',
    '../runtime-platform/fixtures/qa-browser-environment.mjs', '../native-qa-readiness.py'];
  report.source = Object.fromEntries(inputs.map(file => [file, digest(path.join(here, file))]));
  report.releaseReportSHA256 = digest(releaseFile);
  const archive = path.join(out, 'source-inputs'); fs.mkdirSync(archive, {mode: 0o700});
  for (const [file, sha] of Object.entries(report.source)) {
    const target = path.join(archive, sha);
    if (!fs.existsSync(target)) fs.writeFileSync(target, fs.readFileSync(path.join(here, file)), {mode: 0o600, flag: 'wx'});
  }
  const probe = fs.readFileSync(path.join(here, 'probe.mjs'));
  const nonce = crypto.randomBytes(16).toString('hex');
  let origin, observation = null, verdict = null, served = false;
  phase = 'servers'; server = http.createServer(async (req, res) => {
    try {
      res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
      const url = new URL(req.url, origin);
      if (req.method === 'POST' && url.pathname === '/result') {
        assert.equal(req.headers.origin, origin);
        let raw = ''; for await (const part of req) { raw += part; assert(raw.length <= 32768); }
        const data = JSON.parse(raw);
        assert.deepEqual(Object.keys(data).sort(), ['nonce', 'observation']);
        assert.equal(data.nonce, nonce); assert.equal(verdict, null);
        verdict = verifyVoices(data.observation, locale);
        // Failed or extra-field payloads are not copied into diagnostic files.
        if (verdict.status !== 'failed') observation = data.observation;
        res.end('ok'); return;
      }
      assert.equal(req.method, 'GET');
      if (url.pathname === '/probe.mjs') {
        res.setHeader('Content-Type', 'text/javascript'); res.end(probe); return;
      }
      if (url.pathname === '/favicon.ico') { res.writeHead(404); res.end(); return; }
      assert.equal(url.pathname, '/voices'); assert.equal(url.searchParams.get('nonce'), nonce);
      served = true;
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Content-Security-Policy', `default-src 'none'; script-src 'self' 'nonce-${nonce}'; connect-src 'self'`);
      res.end(`<!doctype html><meta charset="utf-8"><title>Own speech QA</title><body data-own-nonce="${nonce}">Own voice metadata QA — no speech playback<script type="module" nonce="${nonce}">
import {observeVoices} from '/probe.mjs';
const observation = await observeVoices({requestedLocale:${JSON.stringify(locale)}});
await fetch('/result', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce:${JSON.stringify(nonce)},observation})});
</script>`);
    } catch { if (!res.headersSent) res.writeHead(400); res.end(); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  origin = 'http://127.0.0.1:' + server.address().port;
  blocker = http.createServer((req, res) => { res.writeHead(502); res.end(); });
  blocker.on('connect', (req, socket) => { socket.end('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n'); });
  await new Promise((resolve, reject) => { blocker.once('error', reject); blocker.listen(0, '127.0.0.1', resolve); });
  phase = 'admission';
  const ready = spawnSync('/usr/local/bin/python3', ['-B', path.join(project, 'scripts/native-qa-readiness.py'), '--check'], {encoding: 'utf8'});
  report.admission = JSON.parse(ready.stdout);
  report.researchAdmission = speechAdmission(report.admission, ready.status, approvedWarningStage);
  if (!report.researchAdmission.allowed) {
    report.status = 'deferred-resource-admission'; throw Error('Resource admission refused');
  }
  profile = fs.mkdtempSync('/private/tmp/neantik-speech.'); fs.chmodSync(profile, 0o700);
  profileIdentity = fs.lstatSync(profile);
  log = fs.openSync(path.join(out, 'runtime-private.log'), 'wx', 0o600);
  const flags = [`--user-data-dir=${profile}`, '--use-mock-keychain', '--no-first-run', '--no-default-browser-check',
    '--new-window', '--remote-debugging-pipe', '--disable-background-networking', '--disable-component-update',
    '--disable-sync', '--disable-extensions', '--disable-quic', '--webrtc-ip-handling-policy=disable_non_proxied_udp',
    `--lang=${locale}`, `--accept-lang=${locale},${locale.split('-')[0]}`,
    `--proxy-server=http://127.0.0.1:${blocker.address().port}`, '--proxy-bypass-list=127.0.0.1',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', 'about:blank'];
  report.launchArguments = flags.map(flag => flag.startsWith('--user-data-dir=') ? '--user-data-dir=<own temporary root>' : flag);
  const env = browserFixtureEnvironment(); if (seed !== null) env.NEANTIK_PROFILE_SEED = String(seed);
  phase = 'launch'; child = spawn(executable, flags, {env, stdio: ['ignore', 'ignore', log, 'pipe', 'pipe'], detached: true});
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
  report.actualBrowser = true;
  pipe = new SpeechPipe(child.stdio[3], child.stdio[4], origin, nonce); phase = 'version-and-owned-target';
  assert.equal((await pipe.command('Browser.getVersion')).product.split('/').at(-1), release.runtime.chromiumVersion);
  const target = await pipe.command('Target.createTarget', {url: 'about:blank'});
  const {sessionId} = await pipe.command('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await pipe.command('Page.enable', {}, sessionId);
  const ownURL = `${origin}/voices?nonce=${nonce}`;
  phase = 'navigation-and-observation';
  const navigation = await pipe.command('Page.navigate', {url: ownURL}, sessionId);
  assert(!navigation.errorText, 'Own page navigation');
  assert(await until(() => verdict !== null, 12000), 'Bounded observation response missing');
  const frame = (await pipe.command('Page.getFrameTree', {}, sessionId)).frameTree?.frame;
  assert(served && frame?.url === ownURL && frame.securityOrigin === origin && !frame.unreachableUrl, 'Own document custody');
  report.documentCustody = true; report.verdict = verdict;
  if (observation) save('observation.json', observation);
  assert.notEqual(verdict.status, 'failed', 'Voice contract failed; see bounded verdict');
  report.status = verdict.status;
} catch (error) {
  failure = error;
  if (report.status !== 'deferred-resource-admission') report.status = 'failed';
  report.failure = {kind: error.name, phase, reason: 'owned speech stage failed; inspect bounded verdict/admission'};
} finally {
  try {
    if (pipe && child?.exitCode === null) await pipe.command('Browser.close').catch(() => {});
    const exited = () => !child || child.exitCode !== null || child.signalCode !== null;
    const graceful = await until(exited, 7000);
    if (!graceful) child?.kill('SIGTERM'); await until(exited, 3000); pipe?.close();
    if (runtime && child) report.processSettlement = await settleOwnedProcesses({
      inspect: () => inventory(runtime), waitFor: until, mainPID: child.pid, uid: process.getuid(),
      signalGroup: pgid => process.kill(pgid, 'SIGTERM')});
    if (profile) {
      const actual = fs.lstatSync(profile);
      assert(actual.ino === profileIdentity.ino && actual.dev === profileIdentity.dev && actual.uid === process.getuid() &&
        actual.isDirectory() && !actual.isSymbolicLink(), 'Own root identity changed');
      fs.rmSync(profile, {recursive: true});
    }
    report.cleanup = {graceful, browserExit: child?.exitCode ?? null, browserSignal: child?.signalCode ?? null,
      ownedProfileRemoved: !!profile, ownedProcessesRemaining: runtime ? inventory(runtime).length : 0};
    if (child) assert(graceful && child.exitCode === 0 && child.signalCode === null, 'Browser did not exit normally');
    if (report.source) for (const [file, hash] of Object.entries(report.source)) assert.equal(digest(path.join(here, file)), hash);
    if (report.releaseReportSHA256) assert.equal(digest(releaseFile), report.releaseReportSHA256);
    if (report.runtime) {
      assert.equal(digest(executable), report.runtime.executableSHA256);
      assert.equal(digest(framework), report.runtime.frameworkSHA256);
    }
  } catch { failure = true; report.status = 'failed'; report.cleanupFailed = true; }
  finally {
    if (log !== undefined) fs.closeSync(log);
    for (const socketServer of [server, blocker]) {
      if (socketServer?.listening) { socketServer.closeAllConnections(); await new Promise(resolve => socketServer.close(resolve)); }
    }
  }
  report.completedAt = new Date().toISOString(); save('report.json', report);
}
console.log(JSON.stringify({status: report.status, actualBrowser: report.actualBrowser,
  requestedLocale: locale, seed, cleanup: report.cleanup, verdict: report.verdict}));
process.exitCode = failure ? report.status === 'deferred-resource-admission' ? 75 : 1 : report.status === 'inconclusive' ? 2 : 0;
