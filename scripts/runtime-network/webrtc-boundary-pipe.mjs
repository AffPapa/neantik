// QA-only CDP scope: one nonce document, three named prefs, one own extension.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {FontLifecyclePipe} from '../runtime-platform/fixtures/font-lifecycle-pipe.mjs';
import {PREF_KEYS} from './webrtc-boundary-semantics.mjs';

export const WEBRTC_PROBE = fs.readFileSync(new URL('./webrtc-boundary-probe.js', import.meta.url), 'utf8');
export const DOCUMENT_READY = '({href:location.href,origin:location.origin,nonce:document.body?.dataset.ownFixture??null,ready:document.readyState})';
export const PREFERENCE_READ = `(async()=>{const deadline=Date.now()+3000;while(Date.now()<deadline){if(document.readyState!=='loading'&&document.body){return JSON.parse(document.body.innerText);}await new Promise(resolve=>setTimeout(resolve,25));}throw Error('OwnedPreferenceDocumentTimeout');})()`;
export const EXTENSION_READ = 'globalThis.OWN_EXTENSION_RECEIPT??null';

export class WebRTCBoundaryPipe extends FontLifecyclePipe {
  #defaults = new Map();
  #frames = new Map();
  #expected = new Map();
  #generation = 0;
  constructor(input, output, origin, extensionOrigin = null) {
    super(input, output, [origin, origin], 16000);
    assert(extensionOrigin === null || /^chrome-extension:\/\/[a-p]{32}$/.test(extensionOrigin));
    this.origin = origin; this.extensionOrigin = extensionOrigin;
    this.urls = new Set([origin + '/', ...PREF_KEYS.map(key => 'chrome://prefs-internals/' + key),
      ...(extensionOrigin ? [extensionOrigin + '/probe.html'] : [])]);
  }
  own(url) { return this.urls?.has(url) ?? false; }
  observe(item) {
    const p = item.params ?? {}, session = item.sessionId ?? p.sessionId;
    if (['Runtime.executionContextsCleared','Runtime.executionContextDestroyed','Target.detachedFromTarget'].includes(item.method)
      || item.method === 'Page.frameNavigated' && !p.frame?.parentId) {
      this.#generation++; this.#defaults.delete(session); this.#frames.delete(session);
    }
    super.observe(item);
    if (item.method === 'Runtime.executionContextCreated' && this.sessions.has(session)) {
      const context = p.context;
      if (context?.auxData?.isDefault === true && [this.origin, 'chrome://prefs-internals', this.extensionOrigin].includes(context.origin)) {
        assert(Number.isInteger(context.id) && typeof context.auxData.frameId === 'string');
        this.#defaults.set(session, {id: context.id, frame: context.auxData.frameId});
      }
    }
  }
  ready(session) { return this.#defaults.has(session); }
  validate(method, params, session) {
    if (method === 'Runtime.evaluate') {
      assert.deepEqual(Object.keys(params).sort(), ['awaitPromise','contextId','expression','returnByValue']);
      const target = this.#expected.get(session), context = this.#defaults.get(session);
      assert(this.sessions.has(session) && this.pages.has(this.sessions.get(session))
        && context?.id === params.contextId && this.#frames.get(session) === context.frame, 'Live owned default realm required');
      assert(params.awaitPromise === true && params.returnByValue === true);
      const allowed = target === this.origin + '/' ? [DOCUMENT_READY, WEBRTC_PROBE]
        : target === this.extensionOrigin + '/probe.html' ? [EXTENSION_READ]
        : PREF_KEYS.some(key => target === 'chrome://prefs-internals/' + key) ? [PREFERENCE_READ] : [];
      assert(allowed.includes(params.expression), 'Expression outside fixed WebRTC scope');
      return;
    }
    return super.validate(method, params, session);
  }
  async command(method, params = {}, session = null) {
    const generation = this.#generation;
    const result = await super.command(method, params, session);
    if (method === 'Page.navigate') this.#expected.set(session, params.url);
    if (method === 'Page.getFrameTree') {
      const frame = result.frameTree?.frame;
      assert(frame && !frame.unreachableUrl && frame.url === this.#expected.get(session) && this.own(frame.url), 'Owned frame navigation not verified');
      this.#frames.set(session, frame.id);
    }
    if (method === 'Runtime.evaluate') {
      assert.equal(generation, this.#generation, 'WebRTC realm changed during read');
      assert(!result.exceptionDetails && result.result && Object.hasOwn(result.result, 'value'), 'Fixed WebRTC operation failed');
    }
    return result;
  }
  async evaluate(expression, session) {
    await this.command('Page.getFrameTree', {}, session);
    const context = this.#defaults.get(session); assert(context);
    const result = await this.command('Runtime.evaluate', {expression, contextId: context.id, awaitPromise: true, returnByValue: true}, session);
    return result.result.value;
  }
}
