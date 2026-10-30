// Read-only correction over immutable native captures,not a replacement run.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {verifyIsolationSuite, isolationSensitivity} from './isolation-verify.mjs';
const here = path.dirname(fileURLToPath(import.meta.url)), project = path.resolve(here, '../..');
const [bindingFile, directory] = process.argv.slice(2);
assert([bindingFile, directory].every(p => p && path.isAbsolute(p)));
const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const originalFile = path.join(directory, 'observations.json'), report = JSON.parse(fs.readFileSync(originalFile));
const binding = {...JSON.parse(fs.readFileSync(bindingFile)), bindingSHA256: digest(bindingFile)};
assert.deepEqual(report.binding, binding);
// Retain the original result. Only this exact unsupported cross-seed uniqueness
// assertion can be corrected here;all lifecycle and operation failures refuse.
assert.equal(report.status, 'failed'); assert.equal(report.failure, undefined);
assert.deepEqual(report.cleanupFailure, {kind: 'AssertionError', message: 'Individual seeds collapsed for this fixed own drawing'});
const sources = report.sourceSHA256;
for (const [name, hash] of Object.entries(sources)) {
  assert(/^[0-9a-f]{64}$/.test(hash)); assert.equal(digest(path.join(directory, 'source-inputs', hash)), hash);
  if (!['run-isolation.mjs', 'isolation-verify.mjs'].includes(name)) assert.equal(digest(path.resolve(here, name)), hash);
}
const retainedProducer = fs.readFileSync(path.join(directory, 'source-inputs', sources['run-isolation.mjs']), 'utf8');
assert(retainedProducer.includes('for (const spec of ISOLATION_PHASES) await run(spec);'));
assert(retainedProducer.includes('assert(await until(() => ownedProcesses().length === 0, 5000))'));
const replayFile = path.join(project, 'runtime/chromium-15612-source-evidence/primary/m156-full-source-replay.json.projection.json');
const replay = JSON.parse(fs.readFileSync(replayFile)); let semantic;
function walk(v) {
  if (Array.isArray(v)) for (const item of v) walk(item);
  else if (v && typeof v === 'object') {
    if (v.label === 'semantic:canvas') { assert.equal(semantic, undefined); semantic = v; }
    for (const item of Object.values(v)) walk(item);
  }
}
walk(replay);
assert.equal(semantic.patchPath, 'root:manager/runtime/nevision-patches/ports/chromium-155.0.8059.40/patches/m155-canvas-native-readback-semantics.patch');
const patchFile = path.join(project, semantic.patchPath.slice('root:manager/'.length));
assert.equal(digest(patchFile), semantic.patchSHA256);
const patch = fs.readFileSync(patchFile, 'utf8');
assert(patch.includes('-    if (read_pixels_successful && RuntimeEnabledFeatures::FingerprintingCanvasImageDataNoiseEnabled())'));
assert(patch.includes('-  if (RuntimeEnabledFeatures::FingerprintingCanvasImageDataNoiseEnabled())'));
const tuple = JSON.parse(fs.readFileSync(path.join(project, 'runtime/apple-device-tuples.json'))).tuples[0];
const verdict = verifyIsolationSuite(report, tuple, report.markers, binding, sources);
const negatives = isolationSensitivity(report, tuple, report.markers, binding, sources);
for (const row of report.rows) assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, row.id + '.json'))), row);
console.log(JSON.stringify({schemaVersion: 1, verdict, originalProducerStatus: report.status,
  originalFailureSHA256: digest(originalFile), correction: 'Offline only:remove unsupported per-drawing cross-seed uniqueness requirement;all storage,seed,cohort,repeat,lifecycle and cleanup gates retained',
  originalFailureRetained: true, nativeReplayed: false,
  sourceEvidence: {M156ReplaySHA256: digest(replayFile), semanticCanvasPatchSHA256: digest(patchFile)},
  currentAnalyzerSHA256: digest(fileURLToPath(import.meta.url)), currentVerifierSHA256: digest(path.join(here, 'isolation-verify.mjs')),
  nativeBindingSHA256: binding.bindingSHA256, runtimeExecutableSHA256: binding.runtimeExecutableSHA256,
  runtimeFrameworkSHA256: binding.runtimeFrameworkSHA256, actualCaptureNegativeControls: negatives,
  rowCaptures: report.rows.map(r => ({id: r.id, sha256: digest(path.join(directory, r.id + '.json')),
    normalExit0: r.closeObservation.browserExit === 0 && r.closeObservation.graceful})),
  initialClassificationError: 'Producer called verification error cleanupFailure even though cleanup was complete;future producer separates verificationFailure',
  releaseQualified: false, managerQualified: false}, null, 2));
