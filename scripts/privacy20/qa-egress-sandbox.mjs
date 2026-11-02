import assert from 'node:assert/strict';

/**
 * QA-only Seatbelt policy. The browser may connect only to exact loopback
 * fixture ports; all routed, direct TCP/UDP, IPv6 and resolver socket egress
 * remains denied. This is test containment, not a product privacy control.
 */
export function localFixtureEgressProfile(tcpPorts) {
  assert(Array.isArray(tcpPorts) && tcpPorts.length > 0);
  const ports = [...new Set(tcpPorts)];
  assert(ports.every(port => Number.isInteger(port) && port >= 1 && port <= 65535));
  const loopbackAllows = ports.map(port =>
    `(allow network-outbound (remote ip "localhost:${port}"))`
  );
  return [
    '(version 1)',
    '(allow default)',
    '(deny network-outbound)',
    '(deny network-outbound (literal "/private/var/run/mDNSResponder"))',
    '(deny network-outbound (literal "/var/run/mDNSResponder"))',
    '(deny mach-lookup (global-name "com.apple.mDNSResponder"))',
    '(deny mach-lookup (global-name "com.apple.SystemConfiguration.DNSConfiguration"))',
    ...loopbackAllows,
    ''
  ].join('\n');
}

/** Remove Chromium resolver suppressions only in the sandboxed boundary probe. */
export function resolverEnabledBoundaryArguments(args) {
  assert(Array.isArray(args) && args.every(value => typeof value === 'string'));
  const result = args.filter(value => !value.startsWith('--host-resolver-rules='));
  const index = result.findIndex(value => value.startsWith('--disable-features='));
  if (index >= 0) {
    const features = result[index].slice('--disable-features='.length).split(',')
      .filter(value => value !== 'AsyncDns' && value !== 'DnsOverHttpsUpgrade');
    if (features.length) result[index] = `--disable-features=${features.join(',')}`;
    else result.splice(index, 1);
  }
  assert(!result.some(value => value.startsWith('--host-resolver-rules=')));
  assert(!result.some(value => value === '--disable-async-dns'));
  assert(!result.some(value => value.startsWith('--disable-features=') &&
    value.split('=', 2)[1].split(',').some(feature =>
      feature === 'AsyncDns' || feature === 'DnsOverHttpsUpgrade')));
  return result;
}
