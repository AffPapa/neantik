// Route evidence is an observed socket linkage, not the configured proxy string.
export function verifyWebSocketRoute(probe, events, mode, transitions) {
  const issues = []; let checks = 0;
  const check = (value, name) => { checks++; if (!value) issues.push(name); };
  check(['protected', 'bypass-control'].includes(mode), 'mode');
  check(probe?.kind === 'owned-websocket-route-operations' && probe.mode === mode, 'report');
  check(Array.isArray(probe?.errors) && probe.errors.length === 0, 'operation-error');
  check(probe?.socketsRemaining === 0, 'page-socket-cleanup');
  check(JSON.stringify(transitions) === '["blocked","recovered"]', 'actual-proxy-transitions');
  check(Array.isArray(probe?.rows) && probe.rows.length === 6, 'six-operations');
  check(Array.isArray(probe?.held) && probe.held.length === 2, 'two-held-tunnels');
  check(Array.isArray(events), 'events');
  for (const protocol of ['ws', 'wss']) {
    const held = probe?.held?.filter(h => h.protocol === protocol);
    check(held?.length === 1, protocol + ':held-once');
    if (mode === 'protected') check(held?.[0]?.abortedByProxyStop === true && held[0].closeCode === 1006, protocol + ':tunnel-aborted');
    else check(held?.[0]?.stillOpenAfterProxyStop === true, protocol + ':bypass-positive');
    for (const phase of ['initial', 'blocked', 'recovered']) {
      const matches = probe?.rows?.filter(r => r.protocol === protocol && r.phase === phase), row = matches?.[0];
      check(matches?.length === 1, protocol + ':' + phase + ':unique');
      if (!row) continue;
      check(row.timedOut === false, protocol + ':' + phase + ':no-timeout');
      const handshakes = events?.filter(e => e.kind === 'handshake' && e.protocol === protocol && e.phase === phase);
      if (phase === 'blocked' && mode === 'protected') {
        check(row.opened === false && row.echoed === false && row.errored === true && row.closeCode === 1006, protocol + ':explicit-failure');
        check(handshakes?.length === 0, protocol + ':no-origin-on-failure');
      } else {
        const validError = phase === 'initial' && mode === 'protected' ? typeof row.errored === 'boolean' : row.errored === false;
        check(row.opened === true && row.echoed === true && validError, protocol + ':' + phase + ':real-echo');
        check(phase === 'initial' && mode === 'protected' ? row.closeCode === 1006 : row.closeCode === 1000, protocol + ':' + phase + ':close');
        check(handshakes?.length === 1 && handshakes[0].echoed === true && handshakes[0].closed === true, protocol + ':' + phase + ':origin');
        check(handshakes?.[0]?.route === (mode === 'protected' ? 'proxy' : 'direct'), protocol + ':' + phase + ':socket-route');
      }
    }
  }
  check(events?.every(e => ['tunnel', 'handshake'].includes(e.kind) && ['ws', 'wss'].includes(e.protocol) && ['initial', 'blocked', 'recovered'].includes(e.phase)), 'closed-event-domain');
  check(events?.filter(e => e.kind === 'tunnel').length === (mode === 'protected' ? 4 : 0), 'actual-tunnel-count');
  check(events?.filter(e => e.kind === 'tunnel').every(e => e.phase !== 'blocked'), 'no-tunnel-on-proxy-refusal');
  return {status: issues.length ? 'failed' : 'passed-scoped-websocket-route', checks, issues, releaseQualified: false};
}
