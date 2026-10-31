import assert from 'node:assert/strict';
import test from 'node:test';
import {settleOwnedProcesses} from './cleanup.mjs';

test('transient separate-PGID helper drains naturally without signals', async () => {
  let reads = 0, signals = 0;
  const result = await settleOwnedProcesses({mainPID: 100, uid: 501,
    inspect: () => ++reads < 3 ? [{pgid: 777, uid: 501}] : [],
    waitFor: async predicate => { for (let i = 0; i < 3; i++) if (predicate()) return true; return false; },
    signalGroup: () => { signals++; }});
  assert.deepEqual(result, {naturalDrain: true, groupSignalled: false});
  assert.equal(signals, 0);
});
test('persistent unknown custody refuses signaling; owned group has bounded settlement', async () => {
  for (const entry of [{pgid: 777, uid: 501}, {pgid: 100, uid: 502}]) {
    let signals = 0;
    await assert.rejects(settleOwnedProcesses({mainPID: 100, uid: 501,
      inspect: () => [entry], waitFor: async predicate => predicate(),
      signalGroup: () => { signals++; }}), /retain profile/);
    assert.equal(signals, 0);
  }
  let alive = true;
  assert.deepEqual(await settleOwnedProcesses({mainPID: 100, uid: 501,
    inspect: () => alive ? [{pgid: 100, uid: 501}] : [], waitFor: async predicate => predicate(),
    signalGroup: pgid => { assert.equal(pgid, -100); alive = false; }}),
  {naturalDrain: false, groupSignalled: true});
});
