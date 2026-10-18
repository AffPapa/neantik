// Pure effect controls for our own guard, not a browser activation measurement.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('./manager-durability-probe.js', import.meta.url), 'utf8');
const marker = source.indexOf('(async () => {'); assert(marker > 0);
const guard = source.slice(0, marker);
let cases = 0;
for (const [trusted, sticky] of [[true, true], [false, true], [true, false], [false, false], [undefined, undefined]]) {
  const events = [], fence = () => {};
  const context = vm.createContext({navigator: {userActivation: sticky === undefined ? undefined : {hasBeenActive: sticky}},
    addEventListener: (type, callback) => { assert.equal(type, 'beforeunload'); assert.equal(callback, fence); events.push('add'); },
    removeEventListener: (type, callback) => { assert.equal(type, 'beforeunload'); assert.equal(callback, fence); events.push('remove'); }});
  vm.runInContext(guard, context, {timeout: 100});
  const result = context.ownDurabilityArm({isTrusted: trusted}, fence);
  assert.equal(result.trusted, trusted === true); assert.equal(result.sticky, sticky === true);
  assert.deepEqual(events, trusted === true && sticky === true ? ['remove', 'add'] : ['remove']); cases++;
}
console.log(JSON.stringify({status: 'PASS own activation guard effects', positive: 1, negative: cases - 1, nativeActivationQualified: false}));
