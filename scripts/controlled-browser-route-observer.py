#!/usr/bin/env python3
"""Independent observer for owned Chromium NetLog qualification fixtures.

Consumes a completed Default trace. Returns component evidence, not a general
privacy verdict or continuing route guarantee. Never returns raw URLs, headers,
addresses, certificate chains, proxy credentials or trace parameters.
"""
from urllib.parse import urlsplit


class RouteObservationError(ValueError):
    """Invalid, incomplete, ambiguous, or contradictory observation."""


def _index(trace):
    try:
        constants = trace['constants']
        if constants['logCaptureMode'] != 'Default':
            raise RouteObservationError('capture mode')
        types = constants['logEventTypes']
        names = {value: key for key, value in types.items()}
        if len(names) != len(types):
            raise RouteObservationError('ambiguous event types')
        events = trace['events']
        if not isinstance(events, list) or not 0 < len(events) <= 500_000:
            raise RouteObservationError('event count')
        groups = {}
        for event in events:
            sid = event['source']['id']
            # Chromium serializes uint32 source IDs through a signed int in
            # NetLogSource::AddToEventParameters. Cross-process certificate
            # verifier IDs legitimately have the high bit set. Keep identity
            # exact; do not drop those contexts or coerce them to another ID.
            if not isinstance(sid, int) or isinstance(sid, bool) or not -(2**31) <= sid <= 2**31 - 1 or sid == 0:
                raise RouteObservationError('source identity')
            if event['type'] not in names or not isinstance(event.get('params', {}), dict):
                raise RouteObservationError('event structure')
            groups.setdefault(sid, []).append(event)
        return names, events, groups
    except (KeyError, TypeError, AttributeError) as error:
        raise RouteObservationError('trace structure') from error


def observe_https_success(trace, *, expected_url, expected_proxy_chain):
    """Bind each nonce request to its controller, job, SOCKS socket and TLS.

    This observer's accepted surface is a new network HTTPS request over a
    SOCKS relay. Cached responses, reused sockets, retries without an observed
    response and missing contexts are rejected rather than inferred successful.
    H1/H2 responses are accepted; QUIC is outside this fixture contract.
    """
    url = urlsplit(expected_url)
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise RouteObservationError('expected HTTPS URL')
    if not isinstance(expected_proxy_chain, str) or not expected_proxy_chain.startswith('[socks5://'):
        raise RouteObservationError('expected SOCKS relay')
    names, events, groups = _index(trace)
    starts = {e['source']['id'] for e in events
              if names[e['type']] == 'URL_REQUEST_START_JOB'
              and e.get('params', {}).get('url') == expected_url}
    if not 1 <= len(starts) <= 4:
        raise RouteObservationError('nonce request absent or excessive')

    def named(source, name):
        return [e for e in groups.get(source, []) if names[e['type']] == name]

    def one_dependency(source, name):
        values = [e.get('params', {}).get('source_dependency', {}).get('id') for e in named(source, name)]
        if any(not isinstance(value, int) or isinstance(value, bool) or not -(2**31) <= value <= 2**31 - 1 or value == 0 for value in values):
            raise RouteObservationError('invalid dependency identity')
        found = set(values)
        if len(found) != 1:
            raise RouteObservationError('dependency missing or ambiguous')
        result = next(iter(found))
        if result not in groups:
            raise RouteObservationError('dependency context missing')
        return result

    phases = trace['constants'].get('logEventPhase', {})
    begin, end = phases.get('PHASE_BEGIN', 1), phases.get('PHASE_END', 2)
    sockets = set()
    protocols = set()
    for sid in starts:
        if any(e.get('params', {}).get('net_error', 0) < 0 for e in groups[sid]):
            raise RouteObservationError('request error')
        if not named(sid, 'HTTP_TRANSACTION_READ_RESPONSE_HEADERS'):
            raise RouteObservationError('response absent')
        controller = one_dependency(sid, 'HTTP_STREAM_JOB_CONTROLLER_BOUND')
        selections = [e.get('params', {}).get('proxy_chain') for e in named(controller, 'HTTP_STREAM_JOB_CONTROLLER_PROXY_SERVER_RESOLVED')]
        if not selections or any(value != expected_proxy_chain for value in selections):
            raise RouteObservationError('route differs')
        job = one_dependency(sid, 'HTTP_STREAM_REQUEST_BOUND_TO_JOB')
        if one_dependency(job, 'HTTP_STREAM_JOB_BOUND_TO_REQUEST') != sid:
            raise RouteObservationError('job belongs to another request')
        socket = one_dependency(job, 'SOCKET_POOL_BOUND_TO_SOCKET')
        tls = named(socket, 'SSL_CONNECT')
        opened = [e for e in tls if e['phase'] == begin]
        completed = [e for e in tls if e['phase'] == end]
        if len(opened) != 1 or len(completed) != 1:
            raise RouteObservationError('TLS incomplete or ambiguous')
        params = completed[0].get('params', {})
        if params.get('net_error', 0) != 0 or not params.get('version') or not params.get('cipher_suite'):
            raise RouteObservationError('TLS failed or unmeasured')
        tunnel = named(socket, 'SOCKS5_CONNECT')
        tunnel_opened = [e for e in tunnel if e['phase'] == begin]
        tunnel_completed = [e for e in tunnel if e['phase'] == end]
        if len(tunnel_opened) != 1 or len(tunnel_completed) != 1 or tunnel_completed[0].get('params', {}).get('net_error', 0) != 0:
            raise RouteObservationError('SOCKS tunnel incomplete')
        sockets.add(socket)
        # Only known protocol labels may leave this observer.
        protocol = params.get('next_proto', '')
        protocols.add(protocol if protocol in ('h2', 'http/1.1', '') else 'other')
    return {'nonceRequestAttempts': len(starts), 'boundTLSConnections': len(sockets),
            'allRequestsSelectedExpectedRelay': True, 'allRequestsBoundToSuccessfulSOCKSAndTLS': True,
            'responseHeadersObserved': True, 'protocols': sorted(protocols),
            'scope': 'point-in-time HTTPS fixture; not continuous route, DNS leak or OS-default upstream trust qualification'}
