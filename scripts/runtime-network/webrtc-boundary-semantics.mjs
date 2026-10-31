// Closed research matrix. A local UDP boundary is not a global anonymity gate.
import assert from 'node:assert/strict';

export const PREF_KEYS = Object.freeze(['webrtc.ip_handling_policy', 'webrtc.ip_handling_url', 'webrtc.local_ips_allowed_urls']);
export const MATCHING_URL = 'http://127.0.0.1:*';
export const NONMATCHING_URL = 'https://nonmatching.invalid';
const descriptor = (id, fields = {}) => Object.freeze({id, guarded: false, extension: false,
  policy: false, localIP: false, url: null, globalPolicy: 'default', expectUDP: true, ...fields});
export const WEBRTC_CASES = Object.freeze([
  descriptor('direct'), descriptor('guarded', {guarded: true, expectUDP: false}),
  descriptor('url-guarded', {guarded: true, url: MATCHING_URL, expectUDP: false}),
  descriptor('extension-direct', {extension: true}),
  descriptor('extension-guarded', {extension: true, guarded: true, expectUDP: false}),
  descriptor('policy-direct', {extension: true, policy: true}),
  descriptor('policy-guarded', {extension: true, policy: true, guarded: true, expectUDP: false}),
  descriptor('localip-direct', {localIP: true}),
  descriptor('localip-guarded', {localIP: true, guarded: true, expectUDP: false}),
  descriptor('url-match', {globalPolicy: 'disable_non_proxied_udp', url: MATCHING_URL}),
  descriptor('url-nonmatch', {globalPolicy: 'disable_non_proxied_udp', url: NONMATCHING_URL, expectUDP: false}),
]);

export function storedPreferences(spec) {
  assert(WEBRTC_CASES.includes(spec));
  return {'webrtc.ip_handling_policy': spec.globalPolicy,
    'webrtc.ip_handling_url': spec.url ? [{url: spec.url, handling: 'default'}] : [],
    'webrtc.local_ips_allowed_urls': spec.localIP ? [MATCHING_URL] : []};
}
export function expectedPreferences(spec) {
  const values=storedPreferences(spec);
  // Command-line prefs override user prefs. Extension and mandatory policy
  // stores have higher priority, while the renderer still enforces the CLI guard.
  if(spec.guarded&&!spec.extension)values[PREF_KEYS[0]]='disable_non_proxied_udp';
  return values;
}
const count = value => Number.isSafeInteger(value) && value >= 0;
const hash = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);

export function verifyWebRTCCase(row, binding) {
  const spec = WEBRTC_CASES.find(item => item.id === row?.id);
  assert(spec, 'Unknown WebRTC matrix case');
  assert(row.actualBrowser === true && row.headed === true);
  for (const name of ['runtimeExecutableSHA256', 'runtimeFrameworkSHA256', 'machOClosureSHA256', 'bindingSHA256']) {
    assert(hash(binding[name]) && row[name] === binding[name], 'Independent runtime binding differs');
  }
  assert(row.document.loaded === true && row.document.nonceMatched === true && row.document.defaultRealm === true);
  assert(row.collector.canaryAcknowledged === true && row.collector.canaryCount === 1
    && row.collector.resetVerified === true && row.collector.countAfterReset === 0, 'Per-case STUN control/reset missing');
  assert.deepEqual(Object.keys(row.preferences).sort(), PREF_KEYS.slice().sort());
  assert.deepEqual(row.preferences, expectedPreferences(spec), 'Stored targeted preferences differ');
  const probe = row.probe;
  assert(probe?.kind === 'owned-webrtc-boundary' && probe.nonceMatched === true
    && probe.gatheringComplete === true && probe.iceGatheringState === 'complete'
    && probe.timedOut === false && probe.rawICEExported === false, 'Incomplete ICE is not a policy PASS');
  assert.deepEqual(Object.keys(probe.candidates).sort(), ['host','other','prflx','relay','srflx']);
  assert(Object.values(probe.candidates).every(count) && Array.isArray(probe.errorCodes)
    && probe.errorCodes.length <= 16 && probe.errorCodes.every(count));
  assert(row.udp.closedAfterBrowserExit === true && row.udp.finalCounters === true
    && count(row.udp.browserRequests) && row.udp.invalidRequests === 0 && row.udp.canaryCount === 1, 'Final UDP observer missing');
  assert(spec.expectUDP ? row.udp.browserRequests > 0 : row.udp.browserRequests === 0, 'UDP boundary differs');
  if (spec.guarded) assert(count(row.proxyRequests) && row.proxyRequests > 0, 'Guarded document did not use own HTTP proxy');
  else assert.equal(row.proxyRequests, 0);
  if (spec.extension) {
    const extension = row.extension;
    assert(extension.nonceMatched === true && extension.runtimeIDMatched === true && extension.policy === spec.policy);
    assert.deepEqual(extension.permissions, ['privacy']);
    assert(extension.final?.error === null && extension.final.value === 'default');
    if (spec.policy) {
      assert.deepEqual(extension.operations, []);
      assert.equal(extension.final.levelOfControl, 'not_controllable');
    } else {
      assert.deepEqual(extension.operations.map(op => op.set.value), ['disable_non_proxied_udp','default']);
      for (const op of extension.operations) assert(op.set.error === null && op.get.error === null
        && op.get.value === op.set.value && op.get.levelOfControl === 'controlled_by_this_extension');
      assert.equal(extension.final.levelOfControl, 'controlled_by_this_extension');
    }
  } else assert.equal(row.extension, null);
  assert(row.cleanup.graceful === true && row.cleanup.exitCode === 0 && row.cleanup.signal === null
    && row.cleanup.forcedTermination === false && row.cleanup.ownedProcessesRemaining === 0
    && row.cleanup.ownedProfileRemoved === true, 'Crash/forced cleanup is not PASS');
  return {status: 'scoped-webrtc-case-pass', id: row.id, UDPObserved: row.udp.browserRequests > 0,
    globalNetworkQualified: false, releaseQualified: false};
}

export function verifyWebRTCSuite(rows, binding) {
  assert(Array.isArray(rows) && rows.length === WEBRTC_CASES.length, 'Incomplete WebRTC matrix');
  assert.deepEqual(rows.map(row => row.id).sort(), WEBRTC_CASES.map(spec => spec.id).sort());
  const results = rows.map(row => verifyWebRTCCase(row, binding));
  return {status: 'eleven-headed-webrtc-boundaries-pass', cases: results.length,
    globalNetworkQualified: false, releaseQualified: false,
    scope: 'Loopback UDP4; stored prefs/getters, URL matching, local extension and profile-local test policy. Not manager relay, OS policy, IPv6/TURN or global networking.'};
}
