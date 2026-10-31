// Owned synthetic fixture controls; never a production browser policy.
import assert from 'node:assert/strict';
export function applyRTCFixturePolicy(mode, args, env) {
  assert(['rtc-proxy', 'rtc-control'].includes(mode));
  assert(args.includes('--use-mock-keychain'));
  assert.equal(env.NEANTIK_PROFILE_PROXY_REQUIRED, '1');
  // LAN must be identical: the responder is loopback, so LAN-deny would
  // independently explain zero STUN packets and confound the RTC comparison.
  delete env.NEANTIK_PROFILE_RTC;
  delete env.NEANTIK_PROFILE_LAN;
  const index = args.indexOf('--webrtc-ip-handling-policy=disable_non_proxied_udp');
  assert(index >= 0);
  if (mode === 'rtc-control') args[index] = '--webrtc-ip-handling-policy=default_public_interface_only';
}

export function assertDisjointMediaIdentifiers(left, right, field) {
  assert(['device', 'group'].includes(field));
  const values = rows => new Set(rows.map(row => row[field]).filter(Boolean));
  const a = values(left), b = values(right);
  assert(a.size > 0 && b.size > 0, 'synthetic media identifier positive controls absent');
  assert.equal([...a].filter(value => b.has(value)).length, 0, 'synthetic media identifier sets overlap');
}
