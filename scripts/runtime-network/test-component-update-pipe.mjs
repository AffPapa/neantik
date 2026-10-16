import assert from 'node:assert/strict';
import {PassThrough} from 'node:stream';
import {ComponentUpdatePipe, COMPONENT_URL, SNAPSHOT, TRIGGER_KNOWN, TRIGGER_UNKNOWN} from './component-update-pipe.mjs';
const input = new PassThrough(), output = new PassThrough();
const pipe = new ComponentUpdatePipe(input, output);
const snapshot = {targetCount: 1, unknownAbsent: true, buttonReady: true, version: '0.0.0.0', status: 'New', domStatus: 'New', checkingLabel: 'Checking', events: []};
input.on('data', raw => {
  const q = JSON.parse(raw.toString().replace(/\0$/, ''));
  const result = q.method === 'Page.getFrameTree' ? {frameTree: {frame: {id: 'owned', url: COMPONENT_URL}}}
    : q.method === 'Runtime.evaluate' ? {result: {type: 'object', value: snapshot}} : {};
  output.write(JSON.stringify({id: q.id, result}) + '\0');
});
pipe.pages.add('owned'); pipe.targets.add('owned'); pipe.sessions.set('session', 'owned');
const created = {method: 'Runtime.executionContextCreated', sessionId: 'session', params: {context: {id: 7, origin: 'chrome://components', auxData: {isDefault: true, frameId: 'owned'}}}};
pipe.observe(created); await pipe.command('Page.getFrameTree', {}, 'session');
const params = expression => ({expression, contextId: 7, awaitPromise: true, returnByValue: true});
let positive = 0, negative = 0;
assert.throws(() => pipe.validate('Runtime.evaluate', params(TRIGGER_KNOWN), 'session')); negative++;
await pipe.evaluate(SNAPSHOT, 'session'); positive++;
for (const expression of [TRIGGER_UNKNOWN, TRIGGER_KNOWN]) { pipe.validate('Runtime.evaluate', params(expression), 'session'); positive++; }
for (const p of [params('arbitrary()'), {...params(SNAPSHOT), contextId: 8}, {...params(SNAPSHOT), awaitPromise: false}, {...params(SNAPSHOT), extra: true}]) {
  assert.throws(() => pipe.validate('Runtime.evaluate', p, 'session')); negative++;
}
assert.throws(() => pipe.validate('Runtime.evaluate', params(SNAPSHOT), 'foreign-session')); negative++;
assert.throws(() => pipe.validate('Page.navigate', {url: 'chrome://settings/'}, 'session')); negative++;
assert.throws(() => pipe.validate('Page.navigate', {url: 'https://example.invalid/'}, 'session')); negative++;
snapshot.targetCount = 0;
await assert.rejects(pipe.evaluate(SNAPSHOT, 'session')); negative++;
assert.throws(() => pipe.validate('Runtime.evaluate', params(TRIGGER_KNOWN), 'session')); negative++;
snapshot.targetCount = 1;
await pipe.evaluate(SNAPSHOT, 'session'); positive++;
for (const [key, value] of [['domStatus', null], ['checkingLabel', ''], ['events', [{event: 7, version: null}]]]) {
  const original = snapshot[key]; snapshot[key] = value;
  await assert.rejects(pipe.evaluate(SNAPSHOT, 'session')); negative++;
  assert.throws(() => pipe.validate('Runtime.evaluate', params(TRIGGER_KNOWN), 'session')); negative++;
  snapshot[key] = original;
}
await pipe.evaluate(SNAPSHOT, 'session'); positive++;
pipe.pages.add('second'); pipe.targets.add('second'); pipe.sessions.set('second-session', 'second');
pipe.observe({method: 'Runtime.executionContextCreated', sessionId: 'second-session', params: {context: {id: 9, origin: 'chrome://components', auxData: {isDefault: true, frameId: 'owned'}}}});
await pipe.command('Page.getFrameTree', {}, 'second-session');
assert.throws(() => pipe.validate('Runtime.evaluate', {...params(TRIGGER_KNOWN), contextId: 9}, 'second-session')); negative++;
pipe.observe({method: 'Runtime.executionContextsCleared', sessionId: 'session', params: {}});
assert.throws(() => pipe.validate('Runtime.evaluate', params(SNAPSHOT), 'session')); negative++;
pipe.observe({...created, params: {context: {id: 8, origin: 'chrome://components', auxData: {isDefault: false, frameId: 'owned'}}}});
assert.throws(() => pipe.validate('Runtime.evaluate', {...params(SNAPSHOT), contextId: 8}, 'session')); negative++;
pipe.close();
console.log(JSON.stringify({status: 'fixed-component-pipe-controls-pass', positive, negative, actualBrowser: false}));
