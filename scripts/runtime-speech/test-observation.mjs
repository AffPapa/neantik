import assert from 'node:assert/strict';
import test from 'node:test';
import {observeVoices} from './probe.mjs';
import {verifyVoices} from './semantics.mjs';

function voice(lang = 'en-US', isDefault = false, localService = true) {
  return {lang, default: isDefault, localService,
    get name() { throw Error('Forbidden voice name access'); },
    get voiceURI() { throw Error('Forbidden voice URI access'); }};
}
function fixture({loaded = false, native = true, voices = [voice('en-US', true), voice('fr-FR')], unstable = false} = {}) {
  const listeners = new Set(); let list = loaded ? voices : [], started = false, reads = 0;
  return {listeners, getVoices() {
    assert.equal(listeners.size, 1, 'listener must precede every read'); reads++;
    if (!started) {
      started = true;
      if (native) queueMicrotask(() => { list = voices; for (const callback of listeners) callback({type: 'voiceschanged', isTrusted: true}); });
    }
    return unstable && reads % 2 === 0 ? [] : list.slice();
  }, addEventListener(type, callback) { assert.equal(type, 'voiceschanged'); listeners.add(callback); },
  removeEventListener(type, callback) { assert.equal(type, 'voiceschanged'); assert(listeners.delete(callback)); },
  dispatchEvent(event) { for (const callback of listeners) callback(event); return true; }};
}
async function observe(synthesis, requestedLocale = 'en-US') {
  const result = await observeVoices({synthesis, requestedLocale,
    navigatorObject: {language: requestedLocale, platform: 'MacIntel'}, timeoutMS: 5,
    makeEvent: () => ({type: 'voiceschanged', isTrusted: false})});
  assert.equal(synthesis.listeners.size, 0);
  return result;
}

test('cold native delivery, repeat reads and cleanup; forbidden getters untouched', async () => {
  const value = await observe(fixture());
  assert.equal(value.initial.count, 0); assert.equal(value.final.count, 2);
  const verdict = verifyVoices(value, 'en-US');
  assert.equal(verdict.status, 'verified-scoped-voice-observation');
  assert.equal(verdict.loadedFromEmpty, true); assert.equal(verdict.catalogChangeProven, false);
  assert.deepEqual(value.events.map(e => e.isTrusted), [false, true]);
  assert(!JSON.stringify(value).includes('voiceURI'));
});

test('initial native delivery with preloaded list does not claim catalog change', async () => {
  const value = await observe(fixture({loaded: true}));
  const verdict = verifyVoices(value, 'en-US');
  assert.equal(verdict.status, 'verified-scoped-voice-observation');
  assert.equal(verdict.loadedFromEmpty, false); assert.equal(verdict.catalogChangeProven, false);
});

test('synthetic event or empty native delivery cannot manufacture PASS', async () => {
  for (const synthesis of [fixture({native: false}), fixture({voices: []})]) {
    const verdict = verifyVoices(await observe(synthesis), 'en-US');
    assert.equal(verdict.status, 'inconclusive'); assert.equal(verdict.nativeDelivery, false);
  }
});

test('missing requested installed language is informational; navigator mismatch is not', async () => {
  const value = await observe(fixture({voices: [voice('en-US', true)]}), 'fr-FR');
  assert.equal(verifyVoices(value, 'fr-FR').status, 'verified-scoped-voice-observation');
  assert.equal(verifyVoices(value, 'fr-FR').requestedVoiceLanguagePresent, false);
  value.navigatorPrimaryMatchesRequested = false;
  assert.equal(verifyVoices(value, 'fr-FR').status, 'failed');
});

test('real probe exposes malformed language, flags and inconsistent repeat reads', async () => {
  for (const voices of [[voice('not_a_locale')], [voice('en-US', 'true')], [voice('en-US', false, 1)]]) {
    assert.equal(verifyVoices(await observe(fixture({voices})), 'en-US').status, 'failed');
  }
  assert.equal(verifyVoices(await observe(fixture({unstable: true})), 'en-US').status, 'failed');
});

test('region mismatch and wrong default count cannot qualify this Chromium policy', async () => {
  for (const [requestedLocale, language] of [['en-US', 'en-GB'], ['fr-FR', 'fr-CA']]) {
    const synthesis = fixture();
    const value = await observeVoices({synthesis, requestedLocale,
      navigatorObject: {language, platform: 'MacIntel'}, timeoutMS: 5,
      makeEvent: () => ({type: 'voiceschanged', isTrusted: false})});
    assert.equal(value.navigatorPrimaryMatchesRequested, true);
    assert.equal(value.navigatorExactMatchesRequested, false);
    assert.equal(verifyVoices(value, requestedLocale).status, 'failed');
  }
  for (const voices of [[voice('en-US')], [voice('en-US', true), voice('fr-FR', true)]]) {
    assert.equal(verifyVoices(await observe(fixture({voices})), 'en-US').status, 'failed');
  }
});

test('unavailable API is inconclusive and cannot smuggle a voice object', async () => {
  const value = await observeVoices({synthesis: null});
  assert.equal(verifyVoices(value, 'en-US').status, 'inconclusive');
  value.initial = {name: 'own rejected marker'};
  assert.equal(verifyVoices(value, 'en-US').status, 'failed');
});

test('failure reads remove listeners without publishing native error messages', async () => {
  const synthesis = fixture(); synthesis.getVoices = () => { throw Error('own-private-rejected-marker'); };
  const value = await observe(synthesis);
  assert.equal(verifyVoices(value, 'en-US').status, 'failed');
  assert(!JSON.stringify(value).includes('own-private-rejected-marker'));
  assert.equal(value.listenerRemoved, true);
});

test('negative oracle controls reject broken and extra fields', async () => {
  const good = await observe(fixture());
  const corruptions = [
    x => { x.voiceURI = 'own-marker'; }, x => { x.schemaVersion++; },
    x => { x.initial.name = 'own-marker'; }, x => { x.events[1].summary.voiceURI = 'own-marker'; },
    x => { x.events[1].isTrusted = 'true'; }, x => { x.listenerBeforeFirstRead = false; },
    x => { x.timerSettled = false; }, x => { x.listenerRemoved = false; },
    x => { x.final.count = -1; }, x => { x.final.countCapped = true; }, x => { x.final.defaultCount = 2; },
    x => { x.final.defaultFlagsBoolean = false; }, x => { x.final.localServiceFlagsBoolean = false; },
    x => { x.final.languageTagsValid = false; }, x => { x.eventsOverflow = true; },
    x => { x.events.push(x.events[0]); }, x => { x.events[0].summary = null; },
    x => { x.repeatStable = false; }, x => { x.status = 'error'; },
    x => { x.requestedLocale = 'de-DE'; }, x => { x.final.requestedPrimaryMatch = false; },
    x => { x.final.count = 0; }, x => { x.events = {}; },
  ];
  for (const mutate of corruptions) {
    const broken = structuredClone(good); mutate(broken);
    assert.equal(verifyVoices(broken, 'en-US').status, 'failed');
  }
});

test('deadline is bounded before any observation', async () => {
  for (const timeoutMS of [0, 5001, NaN]) await assert.rejects(observeVoices({timeoutMS}));
});
