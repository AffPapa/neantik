// Validate the actual embedded expression's return contract, not browser APIs.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const text = fs.readFileSync(new URL('network_observation.js', import.meta.url), 'utf8');
const receipts = [];
const context = vm.createContext({isSecureContext: true, clearTimeout, setTimeout,
  window: {webkit: {messageHandlers: {ownedNetworkResult: {postMessage: value => receipts.push(value)}}}}});
const args = JSON.stringify({nonce: 'owned-test', stunURL: 'stun:127.0.0.1:1'});
const correct = vm.runInContext(`${text}(${args})`, context);
assert.equal(correct, undefined);
assert.equal(receipts.length, 1);
assert.equal(receipts[0].available, false); // Explicitly not a browser PASS.
assert.equal(receipts[0].gatheringComplete, false);
const broken = text.replace(/^void \(async/m, '(async');
assert.notEqual(text, broken);
const prior = vm.runInContext(`${broken}(${args})`, context);
assert.equal(typeof prior.then, 'function');
await prior;
console.log('Embedded result contract and old-Promise negative control PASS;browser not executed');
