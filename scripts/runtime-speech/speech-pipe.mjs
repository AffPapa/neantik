// Own nonce URL only; voice observations never need page-JS evaluation in CDP.
import assert from 'node:assert/strict';
import {FontLifecyclePipe} from '../runtime-platform/fixtures/font-lifecycle-pipe.mjs';

export class SpeechPipe extends FontLifecyclePipe {
  constructor(input, output, origin, nonce) {
    assert(/^[a-f0-9]{32}$/.test(nonce));
    super(input, output, [origin, origin]);
    this.ownURL = `${origin}/voices?nonce=${nonce}`;
  }
  validate(method, params, session) {
    assert(['Browser.getVersion', 'Browser.close', 'Target.createTarget',
      'Target.attachToTarget', 'Page.enable', 'Page.navigate', 'Page.getFrameTree'].includes(method),
    'Method outside speech fixture');
    if (method === 'Page.navigate') assert.equal(params.url, this.ownURL, 'Exact speech nonce URL required');
    super.validate(method, params, session);
  }
}
