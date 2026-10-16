import assert from 'node:assert/strict';
import {PassThrough} from 'node:stream';
import {CompatibilityPipe} from './compat-pipe.mjs';
import {mediaAccepted, pdfAccepted, cleanupWithServer} from './semantics.mjs';
const nonce = 'a'.repeat(32), origin = 'http://127.0.0.1:12345';
const pipe = new CompatibilityPipe(new PassThrough(), new PassThrough(), origin, nonce);
pipe.pages.add('owned'); pipe.targets.add('owned'); pipe.sessions.set('session', 'owned');
const screenshot = {format: 'png', fromSurface: true, captureBeyondViewport: false,
  clip: {x: 0, y: 0, width: 256, height: 256, scale: 0.5}};
let positives = 0, negatives = 0;
for (const url of ['media', 'colours', 'blank']) {
  pipe.validate('Page.navigate', {url: `${origin}/${url}?nonce=${nonce}`}, 'session'); positives++;
}
for (const bad of [`${origin}/private`, 'https://example.invalid/', `${origin}/media?nonce=wrong`]) {
  assert.throws(() => pipe.validate('Page.navigate', {url: bad}, 'session')); negatives++;
}
assert.throws(() => pipe.validate('Page.captureScreenshot', screenshot, 'session')); negatives++;
pipe.confirmed.set('session', `${origin}/media?nonce=${nonce}`);
assert.throws(() => pipe.validate('Page.captureScreenshot', screenshot, 'session')); negatives++;
pipe.confirmed.set('session', `${origin}/colours?nonce=${nonce}`);
pipe.validate('Page.captureScreenshot', screenshot, 'session'); positives++;
for (const bad of [{...screenshot, clip: {...screenshot.clip, width: 1024}}, {...screenshot, quality: 100}]) {
  assert.throws(() => pipe.validate('Page.captureScreenshot', bad, 'session')); negatives++;
}
assert.throws(() => pipe.validate('Page.captureScreenshot', screenshot, 'foreign-session')); negatives++;
assert.throws(() => pipe.validate('Runtime.evaluate', {expression: 'arbitrary()'}, 'session')); negatives++;
pipe.observe({method: 'Page.frameNavigated', sessionId: 'session', params: {frame: {id: 'owned', url: `${origin}/colours?nonce=${nonce}`}}});
assert.throws(() => pipe.validate('Page.captureScreenshot', screenshot, 'session')); negatives++;
pipe.confirmed.set('session', `${origin}/colours?nonce=${nonce}`);
pipe.revokeTarget('owned');
assert.throws(() => pipe.validate('Page.captureScreenshot', screenshot, 'session')); negatives++;
pipe.close();
const colours = {blue: 1200, yellow: 1200, white: 0, correctVerticalOrder: true};
const blank = {blue: 0, yellow: 0, white: 1200, correctVerticalOrder: false};
assert(pdfAccepted('colours', colours, true)); positives++;
assert(pdfAccepted('blank', blank, true)); positives++;
for (const args of [['colours', colours, false], ['blank', colours, false], ['blank', colours, true], ['blank', blank, false], ['blank', {...blank, white: 0}, true]]) {
  assert(!pdfAccepted(...args)); negatives++;
}
assert(!mediaAccepted({status: 'passed-scoped-codec-operations', checks: 1, issues: [], offlineNegativeControls: []}, 1)); negatives++;
assert(!mediaAccepted({status: 'passed-scoped-codec-operations', checks: 1, issues: [], offlineNegativeControls: []}, 0)); negatives++;
let closed = false; const custodyFailure = Error('owned-custody-failed');
await assert.rejects(cleanupWithServer(async () => { throw custodyFailure; }, async () => { closed = true; }), error => error === custodyFailure);
assert(closed); negatives++;
console.log(JSON.stringify({status: 'scoped-pipe-controls-pass', positives, negatives, actualBrowser: false}));
