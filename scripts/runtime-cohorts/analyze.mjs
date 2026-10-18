// Offline qualification of retained receipts. This never launches a browser.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {COHORTS, verifyProbe} from './verify.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const hex = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);

export function verifyEnvelope(row, probe, tuple, binding, sources) {
  assert.equal(row.status, 'observed-scoped-capabilities'); assert.equal(row.actualBrowser, true); assert.equal(row.headed, true);
  assert.equal(row.seed, COHORTS.find(c => c.id === tuple.id)?.seed); assert.equal(row.cohortID, tuple.id);
  for (const key of ['runtimeExecutableSHA256', 'runtimeFrameworkSHA256', 'machOClosureSHA256']) assert.equal(row[key], binding[key]);
  assert(hex(row.bindingSHA256) && row.bindingSHA256 === binding.bindingSHA256);
  assert(hex(row.probeSHA256)); assert.deepEqual(row.sourceSHA256, sources);
  assert.equal(row.macOS, binding.macOS); assert(Number.isInteger(row.browserPID) && row.browserPID > 1);
  assert(row.admission.eligibleForAttempt && row.admission.memoryPressure === 1 && row.admission.thermalState === 0);
  assert.deepEqual(row.cleanup, {processesRemaining: 0, profileRemoved: true, graceful: true, browserExit: 0});
  assert.deepEqual(row.closeObservation, {graceful: true, browserExit: 0, browserSignal: null});
  assert(hex(row.profileRootSHA256)); assert(row.profileCustody.inode > 0 && row.profileCustody.birthtimeMs > 0);
  assert(Number.isFinite(Date.parse(row.startedAt)) && Date.parse(row.finishedAt) > Date.parse(row.startedAt));
  return verifyProbe(probe, tuple);
}

export function sensitivity(row, probe, tuple, binding, sources) {
  const changes = [
    ['runtime', r => r.runtimeFrameworkSHA256 = '0'.repeat(64)], ['closure', r => r.machOClosureSHA256 = '0'.repeat(64)],
    ['binding', r => r.bindingSHA256 = '0'.repeat(64)], ['source', r => r.sourceSHA256 = {}],
    ['seed', r => r.seed++], ['headed', r => r.headed = false], ['not-started', r => r.actualBrowser = false],
    ['resource-refusal', r => r.admission.eligibleForAttempt = false], ['pressure', r => r.admission.memoryPressure = 2],
    ['normal-exit', r => r.closeObservation.browserExit = 9], ['remaining-process', r => r.cleanup.processesRemaining = 1],
    ['profile-not-removed', r => r.cleanup.profileRemoved = false], ['missing-custody', r => r.profileCustody = {}],
  ];
  for (const [name, mutate] of changes) {
    const broken = structuredClone(row); mutate(broken);
    assert.throws(() => verifyEnvelope(broken, probe, tuple, binding, sources), undefined, name);
  }
  const both = (p, change) => { change(p.contexts[0].first); p.contexts[0].repeat = structuredClone(p.contexts[0].first); };
  const operations = [
    ['missing-context', p => p.contexts.pop()], ['context-error', p => p.errors.push('ContextLost')],
    ['identity', p => p.identity.cpu++], ['renderer', p => both(p, v => v.renderer = 'Apple M1 Pro')],
    ['repeat', p => p.contexts[0].repeat.limits.MAX_TEXTURE_SIZE++],
    ['limit-vs-allocation', p => both(p, v => v.limits.MAX_TEXTURE_SIZE /= 2)],
    ['unusable-extension', p => p.contexts[0].extensionsUsable = false], ['framebuffer', p => p.contexts[0].framebufferComplete = false],
    ['max-allocation-error', p => p.contexts[0].boundaryError = 1281], ['oversize-accepted', p => p.contexts[0].oversizeError = 0],
    ['invalid-enum-accepted', p => p.contexts[0].invalidError = 0], ['draw-error', p => p.contexts[0].drawError = 1282],
    ['false-blue-claim', p => p.contexts[0].pixels.fill(0)], ['channel-bound', p => p.contexts[0].pixels[1] = 2],
    ['precision', p => both(p, v => v.precision[0].precision = 0)], ['missing-limit', p => both(p, v => delete v.limits.MAX_VERTEX_ATTRIBS)],
  ];
  for (const [name, mutate] of operations) {
    const broken = structuredClone(probe); mutate(broken);
    assert.throws(() => verifyEnvelope(row, broken, tuple, binding, sources), undefined, name);
  }
  return [...changes.map(x => x[0]), ...operations.map(x => x[0])];
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [bindingFile, ...directories] = process.argv.slice(2);
  assert(bindingFile && path.isAbsolute(bindingFile) && directories.length === 4 && directories.every(p => path.isAbsolute(p)));
  const binding = {...JSON.parse(fs.readFileSync(bindingFile)), bindingSHA256: digest(bindingFile)};
  const tuples = JSON.parse(fs.readFileSync(path.resolve(here, '../../runtime/apple-device-tuples.json'))).tuples;
  const summaries = []; let sources;
  for (let index = 0; index < directories.length; index++) {
    const dir = directories[index], row = JSON.parse(fs.readFileSync(path.join(dir, 'observations.json')));
    const probeFile = path.join(dir, 'probe.json'), probe = JSON.parse(fs.readFileSync(probeFile));
    assert.equal(row.probeSHA256, digest(probeFile)); assert.equal(row.seed, COHORTS[index].seed);
    if (!sources) sources = row.sourceSHA256; else assert.deepEqual(row.sourceSHA256, sources);
    for (const [name, hash] of Object.entries(sources)) {
      assert(hex(hash)); assert.equal(digest(path.resolve(here, name)), hash, 'Producer changed after capture');
      assert.equal(digest(path.join(dir, 'source-inputs', hash)), hash, 'Preserved source mismatch');
    }
    const tuple = tuples.find(t => t.id === row.cohortID);
    verifyEnvelope(row, probe, tuple, binding, sources);
    const negatives = sensitivity(row, probe, tuple, binding, sources);
    summaries.push({cohortID: row.cohortID, seed: row.seed, result: 'scoped-capabilities-pass',
      captureSHA256: digest(path.join(dir, 'observations.json')), probeSHA256: row.probeSHA256,
      WebGLContexts: 2, negativeControls: negatives});
  }
  console.log(JSON.stringify({schemaVersion: 1, result: 'four-issued-cohort-capabilities-pass', summaries,
    runtimeExecutableSHA256: binding.runtimeExecutableSHA256, runtimeFrameworkSHA256: binding.runtimeFrameworkSHA256,
    bindingSHA256: binding.bindingSHA256, analyzerSHA256: digest(fileURLToPath(import.meta.url)),
    actualNativeSessions: 4, hardwareQualified: false, releaseQualified: false,
    scope: 'Four configured cohorts on one Mac. Real WebGL1/2 limits/extensions/precision, repeat reads, bounded maximum texture/error operations. Not qualification on four physical GPU models.'}, null, 2));
}
