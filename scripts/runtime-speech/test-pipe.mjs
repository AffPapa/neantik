import assert from 'node:assert/strict';
import {PassThrough} from 'node:stream';
import test from 'node:test';
import {SpeechPipe} from './speech-pipe.mjs';

function owned() {
  const input = new PassThrough(), output = new PassThrough();
  const pipe = new SpeechPipe(input, output, 'http://127.0.0.1:54321', 'a'.repeat(32));
  pipe.pages.add('own-page'); pipe.targets.add('own-page'); pipe.sessions.set('own-session', 'own-page');
  return {pipe, close() { pipe.close(); input.destroy(); output.destroy(); }};
}
test('fixed seven methods admit only owned page workflow', () => {
  const {pipe, close} = owned();
  try {
    for (const [method, params, session] of [
      ['Browser.getVersion', {}, null], ['Browser.close', {}, null],
      ['Target.createTarget', {url: 'about:blank'}, null],
      ['Target.attachToTarget', {targetId: 'own-page', flatten: true}, null],
      ['Page.enable', {}, 'own-session'], ['Page.navigate', {url: pipe.ownURL}, 'own-session'],
      ['Page.getFrameTree', {}, 'own-session'],
    ]) assert.doesNotThrow(() => pipe.validate(method, params, session));
  } finally { close(); }
});
test('JS, secret reads, navigation escape and unowned sessions are rejected before transport', () => {
  const {pipe, close} = owned();
  try {
    for (const method of ['Runtime.evaluate', 'Runtime.enable', 'Network.getAllCookies',
      'Storage.getCookies', 'ServiceWorker.stopWorker', 'Browser.grantPermissions', 'Target.getTargets']) {
      assert.throws(() => pipe.validate(method, {}, 'own-session'));
    }
    for (const url of ['https://example.com/', pipe.ownURL.replace('a'.repeat(32), 'b'.repeat(32)),
      'http://127.0.0.1:54321/other', pipe.ownURL + '&unexpected=true']) {
      assert.throws(() => pipe.validate('Page.navigate', {url}, 'own-session'));
    }
    assert.throws(() => pipe.validate('Page.enable', {}, 'other-session'));
    assert.throws(() => pipe.validate('Page.getFrameTree', {}, null));
    assert.throws(() => pipe.validate('Browser.close', {unexpected: true}, null));
    assert.throws(() => pipe.validate('Target.createTarget', {url: pipe.ownURL}, null));
    assert.equal(pipe.input.readableLength, 0);
  } finally { close(); }
});
