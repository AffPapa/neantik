// An oracle for this bounded contract, not a universal voice/privacy score.
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exact = (value, keys) => record(value) && Object.keys(value).sort().join('|') === keys.slice().sort().join('|');
const summaryKeys = ['count', 'defaultCount', 'countCapped', 'languageTagsValid', 'defaultFlagsBoolean',
  'localServiceFlagsBoolean', 'requestedExactMatch', 'requestedPrimaryMatch'];
const resultKeys = ['schemaVersion', 'kind', 'status', 'requestedLocale',
  'navigatorPrimaryMatchesRequested', 'navigatorExactMatchesRequested', 'navigatorPlatformIsMac', 'listenerBeforeFirstRead',
  'initial', 'final', 'events', 'syntheticDispatched', 'eventsOverflow', 'repeatStable',
  'listenerRemoved', 'timerSettled', 'error'];

export function verifyVoices(value, expectedLocale) {
  const issues = [];
  const fail = message => { issues.push(message); };
  if (!exact(value, resultKeys)) return {status: 'failed', issues: ['exact observation key set'], nativeDelivery: false, catalogChangeProven: false};
  if (value.schemaVersion !== 1 || value.kind !== 'bounded-voice-locale-events') fail('schema');
  if (value.requestedLocale !== expectedLocale || !['en-US', 'fr-FR'].includes(expectedLocale)) fail('requested locale binding');
  if (!['observed', 'unavailable', 'error'].includes(value.status)) fail('observation status');
  for (const key of ['navigatorPrimaryMatchesRequested', 'navigatorExactMatchesRequested', 'navigatorPlatformIsMac', 'listenerBeforeFirstRead',
    'syntheticDispatched', 'eventsOverflow', 'repeatStable', 'listenerRemoved', 'timerSettled']) {
    if (typeof value[key] !== 'boolean') fail('boolean ' + key);
  }
  const validSummary = summary => {
    if (!exact(summary, summaryKeys)) { fail('exact summary key set'); return false; }
    if (!Number.isSafeInteger(summary.count) || summary.count < 0 || summary.count > 256) fail('bounded voice count');
    for (const key of summaryKeys.slice(2)) if (typeof summary[key] !== 'boolean') fail('summary boolean ' + key);
    // This is the bound Chromium policy, not a general WebKit requirement:
    // SpeechSynthesisImpl sends is_default = (i == 0).
    if (summary.defaultCount !== (summary.count > 0 ? 1 : 0)) fail('Chromium default voice count');
    for (const key of ['languageTagsValid', 'defaultFlagsBoolean', 'localServiceFlagsBoolean']) {
      if (summary[key] !== true) fail('voice field ' + key);
    }
    if (summary.requestedExactMatch && !summary.requestedPrimaryMatch) fail('locale implication');
    if (summary.count === 0 && (summary.requestedExactMatch || summary.requestedPrimaryMatch || summary.countCapped)) fail('empty list contract');
    if (summary.countCapped && summary.count !== 256) fail('count cap contract');
    return true;
  };
  if (value.initial !== null || value.status === 'observed') validSummary(value.initial);
  if (value.final !== null || value.status === 'observed') validSummary(value.final);
  if (!Array.isArray(value.events) || value.events.length > 16) fail('bounded event list');
  let nativeDelivery = false, synthetic = 0;
  for (const event of Array.isArray(value.events) ? value.events : []) {
    if (!exact(event, ['isTrusted', 'summary']) || typeof event.isTrusted !== 'boolean') { fail('event contract'); continue; }
    validSummary(event.summary);
    if (event.isTrusted === true && event.summary?.count > 0) nativeDelivery = true;
    if (event.isTrusted === false) synthetic++;
  }
  if (value.status !== 'observed') {
    if (value.status === 'error') fail('probe error');
    if (value.status === 'unavailable' && (value.initial !== null || value.final !== null ||
        value.events?.length !== 0 || value.error !== null || value.listenerBeforeFirstRead)) fail('unavailable contract');
    return {status: issues.length ? 'failed' : 'inconclusive', issues, nativeDelivery: false, catalogChangeProven: false};
  }
  if (value.error !== null) fail('unexpected error');
  for (const key of ['navigatorPrimaryMatchesRequested', 'navigatorExactMatchesRequested', 'navigatorPlatformIsMac', 'listenerBeforeFirstRead',
    'syntheticDispatched', 'repeatStable', 'listenerRemoved', 'timerSettled']) {
    if (value[key] !== true) fail('required ' + key);
  }
  if (value.eventsOverflow !== false) fail('event bound exceeded');
  if (synthetic !== 1) fail('one synthetic negative control');
  const loadedFromEmpty = nativeDelivery && value.initial?.count === 0 && value.final?.count > 0;
  return {status: issues.length ? 'failed' : nativeDelivery ? 'verified-scoped-voice-observation' : 'inconclusive',
    issues, nativeDelivery, loadedFromEmpty,
    nativeEventMeaning: nativeDelivery ? 'native-list-delivery; not proof of installed-catalog change' : 'not-observed',
    catalogChangeProven: false,
    // Lack of an installed requested language is informational, not a defect.
    requestedVoiceLanguagePresent: value.final?.requestedPrimaryMatch === true};
}

