// Research-only fixed WebUI operations in an owned chrome://components target.
// No caller-selected JS, external navigation, component install or secret API.
import assert from 'node:assert/strict';
import {FontLifecyclePipe} from '../runtime-platform/fixtures/font-lifecycle-pipe.mjs';

export const CRLSET = 'hfnkpimlhhgieaddgfemjhofmfblmnib';
export const UNKNOWN = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
export const COMPONENT_URL = 'chrome://components/';
export const SNAPSHOT = `(async()=>{const {sendWithPromise}=await import('chrome://resources/js/cr.js');const data=await sendWithPromise('requestComponentsData');const rows=data.components.filter(c=>c.id==='${CRLSET}');return {targetCount:rows.length,unknownAbsent:!data.components.some(c=>c.id==='${UNKNOWN}'),version:rows[0]?.version??null,status:rows[0]?.status??null,buttonReady:!!document.querySelector('button.button-check-update[id="${CRLSET}"]'),events:(globalThis.__OWN_COMPONENT_EVENTS??[]).slice(-16)};})()`;
export const TRIGGER_UNKNOWN = `(()=>{chrome.send('checkUpdate',['${UNKNOWN}']);return {unknownTriggered:true};})()`;
export const TRIGGER_KNOWN = `(async()=>{const {addWebUiListener}=await import('chrome://resources/js/cr.js');globalThis.__OWN_COMPONENT_EVENTS=[];addWebUiListener('component-event',e=>{if(e.id==='${CRLSET}'&&globalThis.__OWN_COMPONENT_EVENTS.length<16)globalThis.__OWN_COMPONENT_EVENTS.push({event:e.event,version:e.version??null})});const button=document.querySelector('button.button-check-update[id="${CRLSET}"]');if(!button||button.disabled)throw Error('OwnComponentButtonUnavailable');button.click();return {buttonClicked:true};})()`;
const expressions = new Set([SNAPSHOT, TRIGGER_UNKNOWN, TRIGGER_KNOWN]);

export class ComponentUpdatePipe extends FontLifecyclePipe {
  #defaults = new Map();
  #frames = new Map();
  #generation = 0;
  #snapshotScope = null;
  constructor(input, output) {
    // Base requires a loopback fixture namespace. This adapter's own() below
    // narrows navigation to the one literal internal page instead.
    super(input, output, ['http://127.0.0.1:1', 'http://127.0.0.1:1'], 10000);
  }
  own(url) { return url === COMPONENT_URL; }
  observe(item) {
    const p = item.params ?? {}, session = item.sessionId ?? p.sessionId;
    if (['Runtime.executionContextsCleared', 'Runtime.executionContextDestroyed', 'Target.detachedFromTarget'].includes(item.method)
      || item.method === 'Page.frameNavigated' && !p.frame?.parentId) {
      this.#generation++; this.#snapshotScope = null;
      this.#defaults.delete(session); this.#frames.delete(session);
    }
    super.observe(item);
    if (item.method === 'Runtime.executionContextCreated' && this.sessions.has(session)) {
      const c = p.context;
      if (c?.auxData?.isDefault === true && c.origin === 'chrome://components') {
        assert(Number.isInteger(c.id) && typeof c.auxData.frameId === 'string');
        this.#defaults.set(session, {id: c.id, frame: c.auxData.frameId});
      }
    }
  }
  validate(method, params, session) {
    if (method === 'Runtime.evaluate') {
      assert.deepEqual(Object.keys(params).sort(), ['awaitPromise', 'contextId', 'expression', 'returnByValue']);
      assert(expressions.has(params.expression), 'Expression outside fixed component scope');
      assert(params.awaitPromise === true && params.returnByValue === true);
      const context = this.#defaults.get(session);
      assert(this.sessions.has(session) && this.pages.has(this.sessions.get(session)));
      assert(context && context.id === params.contextId && this.#frames.get(session) === context.frame, 'Live exact internal default realm required');
      if (params.expression !== SNAPSHOT) assert(this.#snapshotScope?.generation === this.#generation
        && this.#snapshotScope.session === session && this.#snapshotScope.contextId === params.contextId,
        'Verified current CRLSet snapshot required');
      return;
    }
    return super.validate(method, params, session);
  }
  async command(method, params = {}, session = null) {
    const generation = this.#generation;
    if (method === 'Runtime.evaluate' && params.expression === SNAPSHOT) this.#snapshotScope = null;
    const result = await super.command(method, params, session);
    if (method === 'Page.getFrameTree') {
      if (result.frameTree?.frame?.url !== COMPONENT_URL) {
        this.#frames.delete(session); this.#snapshotScope = null;
      }
      assert.equal(result.frameTree?.frame?.url, COMPONENT_URL);
      this.#frames.set(session, result.frameTree.frame.id);
    }
    if (method === 'Runtime.evaluate') {
      assert.equal(generation, this.#generation, 'Component realm changed during operation');
      assert(!result.exceptionDetails && result.result?.type === 'object', 'Fixed component operation failed');
      if (params.expression === SNAPSHOT) {
        const v = result.result.value;
        assert(v?.targetCount === 1 && v.unknownAbsent === true && v.buttonReady === true);
        assert(typeof v.version === 'string' && v.version.length <= 80 && typeof v.status === 'string' && v.status.length <= 160);
        assert(Array.isArray(v.events) && v.events.length <= 16);
        this.#snapshotScope = {generation, session, contextId: params.contextId};
      }
    }
    return result;
  }
  async evaluate(expression, session) {
    await this.command('Page.getFrameTree', {}, session);
    const context = this.#defaults.get(session); assert(context, 'Component default realm not ready');
    const result = await this.command('Runtime.evaluate', {expression, contextId: context.id, awaitPromise: true, returnByValue: true}, session);
    return result.result.value;
  }
}
