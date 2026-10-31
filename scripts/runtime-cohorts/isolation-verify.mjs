import assert from 'node:assert/strict';
export const ISOLATION_PHASES = Object.freeze([
  {id: 'a-write', profile: 'A', seed: 11}, {id: 'wrong-root', profile: 'A', seed: 22},
  {id: 'b-write', profile: 'B', seed: 22}, {id: 'a-return', profile: 'A', seed: 11},
]);
const keys = ['localStorage', 'sessionStorage', 'cookie', 'indexedDB', 'cacheStorage', 'workerActive'];
const empty = () => Object.fromEntries(keys.map(k => [k, k === 'workerActive' ? false : null]));
const stored = (marker, session = false) => Object.fromEntries(keys.map(k => [k, k === 'workerActive' ? true : k === 'sessionStorage' && !session ? null : marker]));
export function verifyIsolationCase(row, spec, tuple, markers, binding, sources) {
  const p = row.probe;
  assert.equal(row.id, spec.id); assert.equal(row.seed, spec.seed); assert.equal(row.profile, spec.profile);
  assert(row.actualBrowser && row.headed && row.browserPID > 1); assert.equal(row.status, 'observed');
  for (const key of ['runtimeExecutableSHA256', 'runtimeFrameworkSHA256', 'machOClosureSHA256', 'bindingSHA256']) assert.equal(row[key], binding[key]);
  assert.deepEqual(row.sourceSHA256, sources); assert.equal(row.macOS, binding.macOS);
  assert(/^[0-9a-f]{64}$/.test(row.profileRootSHA256));
  assert(Number.isInteger(row.profileCustody.inode) && row.profileCustody.inode > 0);
  assert(Number.isInteger(row.profileCustody.device) && row.profileCustody.device >= 0);
  assert(Number.isInteger(row.profileCustody.uid) && row.profileCustody.uid >= 0 && row.profileCustody.birthtimeMs > 0);
  assert(row.admission.eligibleForAttempt && row.admission.memoryPressure === 0 && row.admission.thermalState === 0);
  assert.deepEqual(row.closeObservation, {graceful: true, browserExit: 0, browserSignal: null, processesRemaining: 0});
  assert(Number.isFinite(Date.parse(row.startedAt)) && Date.parse(row.finishedAt) > Date.parse(row.startedAt));
  assert.equal(p.schemaVersion, 1); assert.equal(p.phase, spec.id); assert.deepEqual(p.errors, []);
  assert.deepEqual(p.identity, {cpu: tuple.hardwareConcurrency, memory: tuple.webDeviceMemoryGB, screen: tuple.screen,
    renderer: `ANGLE (Apple, ANGLE Metal Renderer: Apple ${tuple.gpuModel}, Unspecified Version)`,
    hints: {platform: 'macOS', platformVersion: tuple.platformVersion, architecture: 'arm', bitness: '64', mobile: false}});
  assert(/^[0-9a-f]{64}$/.test(p.canvas.first)); assert.equal(p.canvas.first, p.canvas.repeat);
  if (spec.id.endsWith('write')) {
    assert.deepEqual(p.before, empty()); assert.equal(row.initialHTTPCookie, null);
    assert.equal(p.writeRefused, false); assert.deepEqual(p.after, stored(markers[spec.profile], true));
  } else {
    assert.deepEqual(p.before, stored(markers.A)); assert.equal(row.initialHTTPCookie, markers.A);
    assert.deepEqual(p.after, p.before); assert.equal(p.writeRefused, spec.id === 'wrong-root');
  }
  return true;
}
export function verifyIsolationSuite(report, tuple, markers, binding, sources) {
  assert.notEqual(markers.A, markers.B);
  assert.equal(report.rows.length, 4);
  for (let i = 0; i < 4; i++) verifyIsolationCase(report.rows[i], ISOLATION_PHASES[i], tuple, markers, binding, sources);
  const [a, broken, b, returned] = report.rows;
  assert.equal(a.profileRootSHA256, broken.profileRootSHA256); assert.equal(a.profileRootSHA256, returned.profileRootSHA256);
  assert.notEqual(a.profileRootSHA256, b.profileRootSHA256); assert.notEqual(a.profileCustody.inode, b.profileCustody.inode);
  assert.deepEqual(a.profileCustody, returned.profileCustody); assert.deepEqual(a.profileCustody, broken.profileCustody);
  assert.equal(a.probe.canvas.first, returned.probe.canvas.first, 'Seed A drifted after restart');
  assert.equal(broken.probe.canvas.first, b.probe.canvas.first, 'Seed B changed with profile path');
  // Distinct profile seeds are configuration identities, not a requirement
  // that every drawing produce unique pixels. Native Canvas semantics can
  // legitimately preserve the same output across the common hardware cohort.
  // Date serializes milliseconds. A sequential await can finish and start
  // its next session within the same millisecond;strict overlap still refuses.
  for (let i = 1; i < 4; i++) assert(Date.parse(report.rows[i - 1].finishedAt) <= Date.parse(report.rows[i].startedAt));
  assert.deepEqual(report.cleanup, {serversClosed: true, processesRemaining: 0, ownRootRemoved: true});
  return {status: 'same-cohort-seed-and-storage-isolation-pass', actualNativeSessions: 4, nativeNegativeControls: 1,
    sameCohort: tuple.id, persistedStores: ['cookie', 'localStorage', 'indexedDB', 'cacheStorage', 'serviceWorker'],
    sessionStorageRestored: false, equalCanvasForOwnDrawing: a.probe.canvas.first === b.probe.canvas.first, releaseQualified: false,
    scope: 'Raw published runtime;two own user-data roots,synthetic seeds11/22 and controlled wrong-root refusal. Not manager/WebKit/multi-Mac/full1.0 qualification.'};
}

export function isolationSensitivity(report, tuple, markers, binding, sources) {
  const both = (r, field, value) => { r.rows[0].probe.before[field] = value; r.rows[0].probe.after[field] = value; };
  const changes = [
    ['missing-return', r => r.rows.pop()], ['same-profile-root', r => r.rows[2].profileRootSHA256 = r.rows[0].profileRootSHA256],
    ['A-state-overwritten', r => r.rows[3].probe.before.indexedDB = markers.B],
    ['B-received-A-cookie', r => r.rows[2].probe.before.cookie = markers.A],
    ['cookie-not-on-wire', r => r.rows[3].initialHTTPCookie = null],
    ['cache-not-durable', r => r.rows[3].probe.before.cacheStorage = null],
    ['worker-not-restored', r => r.rows[3].probe.before.workerActive = false],
    ['session-restored', r => r.rows[3].probe.before.sessionStorage = markers.A],
    ['negative-write-guard-missing', r => r.rows[1].probe.writeRefused = false],
    ['seed-A-drift', r => r.rows[3].probe.canvas.first = r.rows[3].probe.canvas.repeat = '1'.repeat(64)],
    ['seed-B-profile-dependent', r => r.rows[1].probe.canvas.first = r.rows[1].probe.canvas.repeat = '2'.repeat(64)],
    ['different-cohort', r => r.rows[2].probe.identity.cpu++], ['error', r => r.rows[0].probe.errors.push('ProbeError')],
    ['runtime', r => r.rows[0].runtimeExecutableSHA256 = '0'.repeat(64)], ['source', r => r.rows[0].sourceSHA256 = {}],
    ['not-native', r => r.rows[0].actualBrowser = false], ['not-headed', r => r.rows[0].headed = false],
    ['resource-refused', r => r.rows[0].admission.eligibleForAttempt = false], ['pressure-warning', r => r.rows[0].admission.memoryPressure = 1], ['abnormal-exit', r => r.rows[0].closeObservation.browserExit = 9],
    ['wrong-order', r => r.rows[2].startedAt = r.rows[0].startedAt], ['cleanup', r => r.cleanup.ownRootRemoved = false],
    ['stale-local-storage', r => both(r, 'localStorage', markers.B)], ['missing-custody', r => r.rows[2].profileCustody = {}],
  ];
  for (const [name, mutate] of changes) {
    const broken = structuredClone(report); mutate(broken);
    assert.throws(() => verifyIsolationSuite(broken, tuple, markers, binding, sources), undefined, name);
  }
  return changes.map(x => x[0]);
}
