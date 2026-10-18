import fs from 'node:fs';
import assert from 'node:assert/strict';
import {ISOLATION_PHASES, verifyIsolationSuite, isolationSensitivity} from './isolation-verify.mjs';
const tuple = JSON.parse(fs.readFileSync(new URL('../../runtime/apple-device-tuples.json', import.meta.url))).tuples[0];
const markers = {A: 'own-A', B: 'own-B'}, binding = {runtimeExecutableSHA256: 'a'.repeat(64), runtimeFrameworkSHA256: 'b'.repeat(64),
  machOClosureSHA256: 'c'.repeat(64), bindingSHA256: 'd'.repeat(64), macOS: 'owned-test-os'}, sources = {own: 'e'.repeat(64)};
const keys = ['localStorage', 'sessionStorage', 'cookie', 'indexedDB', 'cacheStorage', 'workerActive'];
const empty = Object.fromEntries(keys.map(k => [k, k === 'workerActive' ? false : null]));
const stored = (marker, session) => Object.fromEntries(keys.map(k => [k, k === 'workerActive' ? true : k === 'sessionStorage' && !session ? null : marker]));
const identity = {cpu: tuple.hardwareConcurrency, memory: tuple.webDeviceMemoryGB, screen: tuple.screen,
  renderer: 'ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)',
  hints: {platform: 'macOS', platformVersion: tuple.platformVersion, architecture: 'arm', bitness: '64', mobile: false}};
const rows = ISOLATION_PHASES.map((spec, index) => ({id: spec.id, seed: spec.seed, profile: spec.profile, status: 'observed',
  actualBrowser: true, headed: true, browserPID: 2000 + index, ...binding, sourceSHA256: sources,
  profileRootSHA256: (spec.profile === 'A' ? '1' : '2').repeat(64), profileCustody: {inode: spec.profile === 'A' ? 1 : 2, device: 1, uid: 42, birthtimeMs: 1000},
  admission: {eligibleForAttempt: true, memoryPressure: 1, thermalState: 0},
  closeObservation: {graceful: true, browserExit: 0, browserSignal: null, processesRemaining: 0},
  startedAt: new Date(10000 + index * 2000).toISOString(), finishedAt: new Date(11000 + index * 2000).toISOString(),
  initialHTTPCookie: spec.id.endsWith('write') ? null : markers.A,
  probe: {schemaVersion: 1, phase: spec.id, errors: [], identity: structuredClone(identity),
    canvas: {first: (spec.seed === 11 ? 'a' : 'b').repeat(64), repeat: (spec.seed === 11 ? 'a' : 'b').repeat(64)},
    writeRefused: spec.id === 'wrong-root', before: spec.id.endsWith('write') ? structuredClone(empty) : stored(markers.A, false),
    after: spec.id.endsWith('write') ? stored(markers[spec.profile], true) : stored(markers.A, false)}}));
const report = {rows, cleanup: {serversClosed: true, processesRemaining: 0, ownRootRemoved: true}};
assert.equal(verifyIsolationSuite(report, tuple, markers, binding, sources).status, 'same-cohort-seed-and-storage-isolation-pass');
const negatives = isolationSensitivity(report, tuple, markers, binding, sources);
const sharedCanvas = structuredClone(report);
for (const row of sharedCanvas.rows) row.probe.canvas = {first: 'c'.repeat(64), repeat: 'c'.repeat(64)};
assert.equal(verifyIsolationSuite(sharedCanvas, tuple, markers, binding, sources).equalCanvasForOwnDrawing, true);
const equalBoundary = structuredClone(report); equalBoundary.rows[1].startedAt = equalBoundary.rows[0].finishedAt;
assert.equal(verifyIsolationSuite(equalBoundary, tuple, markers, binding, sources).status, 'same-cohort-seed-and-storage-isolation-pass');
console.log(JSON.stringify({status: 'PASS', modeledPositive: 3, modeledNegative: negatives.length, actualBrowser: false}));
