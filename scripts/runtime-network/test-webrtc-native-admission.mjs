import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {hasNormalWebRTCAdmission} from './webrtc-native-admission.mjs';

const scripts = fileURLToPath(new URL('../', import.meta.url));

test('Chromium launch admission agrees with the Python observer', () => {
  const result = spawnSync('python3', ['-B', '-c', [
    'import importlib, json',
    'qa = importlib.import_module("native-qa-readiness")',
    'samples = [(1, 0), (1, 1), (0, 0), (2, 0), (4, 0), (1, 2), (None, 0)]',
    'print(json.dumps([(qa.exit_code(r), r) for r in [qa.assess(*p) for p in samples]]))',
  ].join('\n')], {cwd: scripts, encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).map(([status, snapshot]) =>
    hasNormalWebRTCAdmission(status, snapshot)), [true, true, false, false, false, false, false]);
});

test('inconsistent or unsupported admission evidence is refused', () => {
  const normal = {schemaVersion: 1, eligibleForAttempt: true, memoryPressure: 1, thermalState: 0, reasons: []};
  assert.equal(hasNormalWebRTCAdmission(0, normal), true);
  assert.equal(hasNormalWebRTCAdmission(75, normal), false);
  for (const snapshot of [
    null, {...normal, schemaVersion: 2}, {...normal, eligibleForAttempt: false},
    {...normal, memoryPressure: true}, {...normal, reasons: ['memory_pressure_warning']},
  ]) assert.equal(hasNormalWebRTCAdmission(0, snapshot), false);
});
