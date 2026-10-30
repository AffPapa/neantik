// Owned cold-page observation. Never read voice names/URIs or synthesize speech.
const boolean = value => typeof value === 'boolean';
const primary = value => new Intl.Locale(value).language;

export async function observeVoices({synthesis = globalThis.speechSynthesis,
  requestedLocale = 'en-US', navigatorObject = globalThis.navigator,
  timeoutMS = 2000, makeEvent = () => new Event('voiceschanged')} = {}) {
  if (!Number.isInteger(timeoutMS) || timeoutMS < 1 || timeoutMS > 5000) throw Error('Invalid observation deadline');
  const requestedTag = new Intl.Locale(requestedLocale).toString(), requestedPrimary = primary(requestedLocale);
  const result = {schemaVersion: 1, kind: 'bounded-voice-locale-events', status: 'not-run',
    requestedLocale, navigatorPrimaryMatchesRequested: false, navigatorExactMatchesRequested: false, navigatorPlatformIsMac: false,
    listenerBeforeFirstRead: false, initial: null, final: null, events: [],
    syntheticDispatched: false, eventsOverflow: false, repeatStable: true,
    listenerRemoved: false, timerSettled: false, error: null};
  if (!synthesis || typeof synthesis.getVoices !== 'function' ||
      typeof synthesis.addEventListener !== 'function' || typeof synthesis.removeEventListener !== 'function') {
    result.status = 'unavailable'; return result;
  }
  let listener, timer, eventReadFailed = false;
  const read = () => {
    const list = synthesis.getVoices();
    if (!Array.isArray(list) || list.length > 1024) throw Error('Voice list bounds');
    // Only these three fields are read. Retain raw tags in memory only to
    // compare adjacent reads; the returned observation has booleans/counts.
    const fields = list.map(voice => [voice.lang, voice.default, voice.localService]);
    let tagsValid = true, exact = false, languageMatch = false;
    for (const [tag] of fields) {
      try {
        if (typeof tag !== 'string' || !tag || tag.length > 128) throw Error('Invalid tag');
        const locale = new Intl.Locale(tag);
        exact ||= locale.toString() === requestedTag;
        languageMatch ||= locale.language === requestedPrimary;
      } catch { tagsValid = false; }
    }
    return {fields, summary: {count: Math.min(list.length, 256), countCapped: list.length > 256,
      defaultCount: Math.min(fields.filter(x => x[1] === true).length, 256),
      languageTagsValid: tagsValid, defaultFlagsBoolean: fields.every(x => boolean(x[1])),
      localServiceFlagsBoolean: fields.every(x => boolean(x[2])),
      requestedExactMatch: exact, requestedPrimaryMatch: languageMatch}};
  };
  const sample = () => {
    const first = read(), second = read();
    result.repeatStable &&= JSON.stringify(first.fields) === JSON.stringify(second.fields);
    return first.summary;
  };
  try {
    result.navigatorPrimaryMatchesRequested = primary(navigatorObject.language) === requestedPrimary;
    result.navigatorExactMatchesRequested = new Intl.Locale(navigatorObject.language).toString() === requestedTag;
    result.navigatorPlatformIsMac = typeof navigatorObject.platform === 'string' && navigatorObject.platform.startsWith('Mac');
    listener = event => {
      if (result.events.length === 16) { result.eventsOverflow = true; return; }
      try {
        if (event.type !== 'voiceschanged' || !boolean(event.isTrusted)) throw Error('Event contract');
        result.events.push({isTrusted: event.isTrusted, summary: sample()});
      } catch { eventReadFailed = true; }
    };
    synthesis.addEventListener('voiceschanged', listener);
    result.listenerBeforeFirstRead = true;
    result.initial = sample();
    // Prove this runner does not mistake dispatchEvent for native delivery.
    if (typeof synthesis.dispatchEvent === 'function') {
      synthesis.dispatchEvent(makeEvent()); result.syntheticDispatched = true;
    }
    await new Promise(resolve => { timer = setTimeout(() => { result.timerSettled = true; resolve(); }, timeoutMS); });
    result.final = sample();
    result.status = eventReadFailed ? 'error' : 'observed';
    if (eventReadFailed) result.error = 'event-read-failed';
  } catch { result.status = 'error'; result.error = 'observation-failed'; }
  finally {
    if (timer !== undefined) clearTimeout(timer);
    if (listener) {
      try { synthesis.removeEventListener('voiceschanged', listener); result.listenerRemoved = true; }
      catch { result.status = 'error'; result.error = 'listener-cleanup-failed'; }
    }
  }
  return result;
}
