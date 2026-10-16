import test from 'node:test';
import assert from 'node:assert/strict';
import {speechAdmission} from './admission.mjs';
const warning = {eligibleForAttempt: false, memoryPressure: 2, thermalState: 1, reasons: ['memory_pressure_warning']};
test('normal remains eligible without an exception', () => {
  assert.deepEqual(speechAdmission({...warning, eligibleForAttempt: true, memoryPressure: 1, reasons: []}, 0),
    {allowed: true, approvedWarningUsed: false});
});
test('warning requires fresh explicit stage approval', () => {
  assert.equal(speechAdmission(warning, 75).allowed, false);
  assert.deepEqual(speechAdmission(warning, 75, true), {allowed: true, approvedWarningUsed: true});
});
test('critical unknown overheating setup errors and contradictory reports always refuse', () => {
  for (const value of [null, {...warning, memoryPressure: 4}, {...warning, memoryPressure: null},
    {...warning, thermalState: 2}, {...warning, thermalState: 3}, {...warning, thermalState: null},
    {...warning, eligibleForAttempt: true}, {...warning, reasons: []},
    {...warning, reasons: ['memory_pressure_warning', 'thermal_unknown']}]) {
    assert.equal(speechAdmission(value, 75, true).allowed, false);
  }
  for (const status of [0, 1, 78, null]) assert.equal(speechAdmission(warning, status, true).allowed, false);
  assert.equal(speechAdmission(warning, 75, 'yes').allowed, false);
});
