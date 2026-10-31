// Offline capture verification. Does not open a browser or alter a receipt.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {verifyWebSocketRoute} from './websocket-route-verify.mjs';
import {mutations} from './test-websocket-route.mjs';
const [bindingFile, bypass, protectedRun] = process.argv.slice(2);
assert([bindingFile, bypass, protectedRun].every(p => p && path.isAbsolute(p)));
const here = path.dirname(fileURLToPath(import.meta.url));
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const binding = JSON.parse(fs.readFileSync(bindingFile));
const results = [];
for (const [mode, directory] of [['bypass-control', bypass], ['protected', protectedRun]]) {
  const reportBytes = fs.readFileSync(path.join(directory, 'observations.json'));
  const r = JSON.parse(reportBytes), probeBytes = fs.readFileSync(path.join(directory, 'probe.json')), probe = JSON.parse(probeBytes);
  assert.equal(r.probeSHA256, sha(probeBytes)); assert.equal(r.bindingSHA256, sha(fs.readFileSync(bindingFile)));
  assert(r.status === 'observed-scoped-websocket-route' && r.actualBrowser === true && r.headed === true && r.mode === mode);
  assert(r.admission.memoryPressure === 0 && r.admission.thermalState === 0 && r.admission.eligibleForAttempt === true);
  for (const field of ['runtimeExecutableSHA256', 'runtimeFrameworkSHA256', 'machOClosureSHA256']) assert.equal(r[field], binding[field]);
  assert(r.closeObservation.graceful && r.closeObservation.browserExit === 0 && r.closeObservation.browserSignal === null);
  assert(r.cleanup.processesRemaining === 0 && r.cleanup.rootRemoved && r.cleanup.graceful && r.cleanup.browserExit === 0 && r.cleanup.forcedCleanup === false);
  assert(r.ownTLSKeyRemoved && r.controlListenerClosed && r.fixtureCleanup.listenersClosed && r.fixtureCleanup.socketsRemaining === 0);
  const changedInputs = [];
  for (const [name, hash] of Object.entries(r.sourceSHA256)) {
    const archived = fs.readFileSync(path.join(directory, 'source-inputs', hash)); assert.equal(sha(archived), hash);
    const current = fs.readFileSync(path.join(here, name));
    if (sha(current) !== hash) {
      assert(mode === 'bypass-control' && name === 'websocket-fixture.mjs');
      // Only the diagnosed FIN/drain repair may differ from the original
      // positive control. Never rewrite its original producer/hash receipt.
      const prior = current.toString().replace("      // HTTP-upgraded sockets can remain half-open after a proxy sends FIN.\n      // Complete the owned peer's TCP shutdown; do not fabricate a WS close.\n      socket.once('end', () => socket.end());\n", '')
        .replace("    const closed = [...this.sockets].map(socket => new Promise(resolve => { socket.once('close', resolve); socket.destroy(); }));\n    await Promise.all([...closed, ...[this.proxy, this.ws, this.wss]", "    for (const socket of this.sockets) socket.destroy();\n    await Promise.all([this.proxy, this.ws, this.wss]")
        .replace('    }))]);', '    })));');
      assert.equal(sha(prior), hash, 'Different source change cannot reuse the original bypass control');
      changedInputs.push({name, change: 'only FIN/drain repair;original positive close evidence retained'});
    }
  }
  const verdict = verifyWebSocketRoute(probe, r.events, mode, r.transitions); assert.equal(verdict.issues.length, 0);
  const negatives = [];
  if (mode === 'protected') for (const [name, mutate] of mutations) {
    const candidate = {probe: structuredClone(probe), events: structuredClone(r.events), transitions: [...r.transitions], mode};
    mutate(candidate); const v = verifyWebSocketRoute(candidate.probe, candidate.events, mode, candidate.transitions);
    assert(v.issues.length > 0, 'Actual capture sensitivity: ' + name); negatives.push(name);
  }
  results.push({mode, reportSHA256: sha(reportBytes), checks: verdict.checks, issues: [],
    handshakes: r.events.filter(e => e.kind === 'handshake').length,
    directHandshakes: r.events.filter(e => e.kind === 'handshake' && e.route === 'direct').length,
    proxyHandshakes: r.events.filter(e => e.kind === 'handshake' && e.route === 'proxy').length,
    negativeCaptureMutations: negatives, retainedProducerDifference: changedInputs,
    sourceSHA256: r.sourceSHA256, lifecycle: 'normal main exit0;no forced cleanup;own processes/listeners/root/key gone'});
}
// The actual bypass capture must fail if mislabeled as protected.
const direct = JSON.parse(fs.readFileSync(path.join(bypass, 'probe.json'))), directReport = JSON.parse(fs.readFileSync(path.join(bypass, 'observations.json')));
direct.mode = 'protected'; assert(verifyWebSocketRoute(direct, directReport.events, 'protected', directReport.transitions).issues.length > 0);
console.log(JSON.stringify({schemaVersion: 1, status: 'passed-scoped-websocket-route-pair', runtimeVersion: binding.runtimeVersion,
  runtimeExecutableSHA256: binding.runtimeExecutableSHA256, machOClosureSHA256: binding.machOClosureSHA256,
  macOS: binding.macOS, architecture: binding.architecture, cases: results, actualBypassRejectedAsProtected: true,
  releaseQualified: false, managerQualified: false, WebKitQualified: false}, null, 2));
