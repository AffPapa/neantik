// A crop of this fixture's own PDF host only. No page JS or arbitrary URLs.
import assert from 'node:assert/strict';
import {FontLifecyclePipe} from '../runtime-platform/fixtures/font-lifecycle-pipe.mjs';

export class CompatibilityPipe extends FontLifecyclePipe {
  constructor(input, output, origin, nonce) {
    super(input, output, [origin, origin], 10000);
    assert(/^[a-f0-9]{32}$/.test(nonce));
    this.allowedURLs = new Set(['media', 'colours', 'blank'].map(name => `${origin}/${name}?nonce=${nonce}`));
    this.confirmed = new Map();
  }
  observe(item) {
    if (['Page.frameNavigated', 'Runtime.executionContextsCleared', 'Target.detachedFromTarget'].includes(item.method)) {
      this.confirmed.delete(item.sessionId ?? item.params?.sessionId);
    }
    super.observe(item);
  }
  validate(method, params, session) {
    if (method === 'Page.captureScreenshot') {
      assert(this.sessions.has(session) && this.pages.has(this.sessions.get(session)));
      assert(this.confirmed.get(session)?.includes('/colours?') || this.confirmed.get(session)?.includes('/blank?'));
      assert.deepEqual(params, {format: 'png', fromSurface: true, captureBeyondViewport: false,
        clip: {x: 0, y: 0, width: 256, height: 256, scale: 0.5}});
      return;
    }
    if (method === 'Page.navigate') {
      assert(this.allowedURLs.has(params.url), 'Only exact owned nonce URLs');
      this.confirmed.delete(session);
    }
    return super.validate(method, params, session);
  }
  async command(method, params = {}, session = null) {
    const result = await super.command(method, params, session);
    if (method === 'Page.getFrameTree') {
      const url = result.frameTree?.frame?.url;
      assert(this.allowedURLs.has(url));
      this.confirmed.set(session, url);
    }
    return result;
  }
}
