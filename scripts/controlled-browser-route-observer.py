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
        if not isinstance(types, dict) or any(not isinstance(key, str) or not key or
                type(value) is not int or not 0 <= value <= 2**31 - 1 for key, value in types.items()):
            raise RouteObservationError('event types')
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
            if type(event['type']) is not int or event['type'] not in names or not isinstance(event.get('params', {}), dict):
                raise RouteObservationError('event structure')
            if type(event.get('phase')) is not int or event['phase'] not in (0, 1, 2):
                raise RouteObservationError('event phase')
            groups.setdefault(sid, []).append(event)
        return names, events, groups
    except (KeyError, TypeError, AttributeError) as error:
        raise RouteObservationError('trace structure') from error


def _net_error(params):
    # bool is an int subclass in Python, but not a Chromium error number.
    value = params.get('net_error', 0)
    if type(value) is not int or not -(2**31) <= value <= 0:
        raise RouteObservationError('invalid network error')
    return value


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
    # Chromium retains the URLRequest source ID across redirects. Bind only
    # the exact nonce-bearing leg, rather than borrowing another leg's job,
    # controller or response. Keep all its failed/repeated attempts visible.
    legs = []
    for sid, request_events in groups.items():
        boundaries = [i for i, e in enumerate(request_events)
                      if names[e['type']] == 'URL_REQUEST_START_JOB'
                      and 'url' in e.get('params', {})]
        for index, start in enumerate(boundaries):
            if request_events[start]['params']['url'] == expected_url:
                end = boundaries[index + 1] if index + 1 < len(boundaries) else len(request_events)
                legs.append((sid, request_events[start:end]))
    if not 1 <= len(legs) <= 4:
        raise RouteObservationError('nonce request absent or excessive')

    request_override = {}

    def named(source, name):
        return [e for e in request_override.get(source, groups.get(source, [])) if names[e['type']] == name]

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
    if type(begin) is not int or type(end) is not int or (begin, end) != (1, 2):
        raise RouteObservationError('phase constants')
    sockets = set()
    protocols = set()
    for sid, request_events in legs:
        request_override = {sid: request_events}
        if any(_net_error(e.get('params', {})) < 0 for e in request_events):
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
        if len(tls) != 2 or len(opened) != 1 or len(completed) != 1:
            raise RouteObservationError('TLS incomplete or ambiguous')
        params = completed[0].get('params', {})
        cipher = params.get('cipher_suite')
        if _net_error(params) != 0 or params.get('version') not in ('TLS 1.2', 'TLS 1.3') or type(cipher) is not int or not 1 <= cipher <= 65535:
            raise RouteObservationError('TLS failed or unmeasured')
        tunnel = named(socket, 'SOCKS5_CONNECT')
        tunnel_opened = [e for e in tunnel if e['phase'] == begin]
        tunnel_completed = [e for e in tunnel if e['phase'] == end]
        if len(tunnel) != 2 or len(tunnel_opened) != 1 or len(tunnel_completed) != 1 or _net_error(tunnel_completed[0].get('params', {})) != 0:
            raise RouteObservationError('SOCKS tunnel incomplete')
        sockets.add(socket)
        # Only known protocol labels may leave this observer.
        protocol = params.get('next_proto', '')
        if not isinstance(protocol, str) or len(protocol) > 64:
            raise RouteObservationError('invalid negotiated protocol')
        protocols.add(protocol if protocol in ('h2', 'http/1.1', '') else 'other')
    return {'nonceRequestAttempts': len(legs), 'boundTLSConnections': len(sockets),
            'allRequestsSelectedExpectedRelay': True, 'allRequestsBoundToSuccessfulSOCKSAndTLS': True,
            'responseHeadersObserved': True, 'protocols': sorted(protocols),
            'scope': 'point-in-time HTTPS fixture; not continuous route, DNS leak or OS-default upstream trust qualification'}


def observe_background_attempts(trace, *, expected_proxy_chain, owned_fixture_host):
    """Redacted request inventory, including unresolved/failed and redirected legs.

    A selected proxy is not a successful socket or an on-wire DNS measurement.
    This function therefore never returns a general privacy/route PASS. Domain
    categories describe addresses only; they do not prove a request's purpose.
    """
    import re
    match = re.fullmatch(r'\[socks5://127\.0\.0\.1:([0-9]{1,5})\]', expected_proxy_chain or '')
    if not match or not 1 <= int(match[1]) <= 65535:
        raise RouteObservationError('expected owned relay')
    if not isinstance(owned_fixture_host, str) or not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)*\.test', owned_fixture_host):
        raise RouteObservationError('expected fixture host')
    names, events, groups = _index(trace)
    routes = ('expectedRelay', 'direct', 'other', 'mixed', 'unobserved')
    categories = {key: dict(attempts=0, responseHeaders=0, failed=0,
                           selectedRoutes={route: 0 for route in routes})
                  for key in ('ownedFixture', 'vendorRelated', 'unclassified')}
    unsupported = 0
    positions = {id(event): index for index, event in enumerate(events)}
    for request_events in groups.values():
        starts = [i for i, e in enumerate(request_events)
                  if names[e['type']] == 'URL_REQUEST_START_JOB' and 'url' in e.get('params', {})]
        for position, start in enumerate(starts):
            last = starts[position + 1] if position + 1 < len(starts) else len(request_events)
            leg = request_events[start:last]
            first_position = positions[id(leg[0])]
            last_position = positions[id(request_events[last])] if last < len(request_events) else len(events)
            raw_url = leg[0]['params']['url']
            if not isinstance(raw_url, str) or len(raw_url) > 16384:
                raise RouteObservationError('request URL structure')
            try:
                url = urlsplit(raw_url)
                if url.username or url.password:
                    raise RouteObservationError('credential-bearing URL')
                hostname = url.hostname
            except ValueError as error:
                raise RouteObservationError('request URL structure') from error
            if url.scheme not in ('http', 'https'):
                unsupported += 1
                continue
            if not hostname:
                raise RouteObservationError('request host missing')
            vendor_roots = ('google.com', 'googleapis.com', 'gstatic.com', 'chromium.org', 'googleusercontent.com')
            category = 'ownedFixture' if hostname == owned_fixture_host else (
                'vendorRelated' if any(hostname == root or hostname.endswith('.' + root) for root in vendor_roots)
                else 'unclassified')
            counter = categories[category]
            counter['attempts'] += 1
            counter['responseHeaders'] += int(any(names[e['type']] == 'HTTP_TRANSACTION_READ_RESPONSE_HEADERS' for e in leg))
            counter['failed'] += int(any(_net_error(e.get('params', {})) < 0 for e in leg))
            selections = []
            missing = False
            for e in leg:
                if names[e['type']] != 'HTTP_STREAM_JOB_CONTROLLER_BOUND':
                    continue
                dependency_record = e.get('params', {}).get('source_dependency')
                if not isinstance(dependency_record, dict):
                    raise RouteObservationError('invalid controller dependency')
                dependency = dependency_record.get('id')
                if type(dependency) is not int or dependency == 0 or not -(2**31) <= dependency <= 2**31 - 1:
                    raise RouteObservationError('invalid controller dependency')
                controller = groups.get(dependency)
                if controller is None:
                    missing = True
                    continue
                found = [e.get('params', {}).get('proxy_chain') for e in controller
                         if names[e['type']] == 'HTTP_STREAM_JOB_CONTROLLER_PROXY_SERVER_RESOLVED'
                         and first_position <= positions[id(e)] < last_position]
                if not found:
                    missing = True
                for chain in found:
                    if not isinstance(chain, str) or not chain or len(chain) > 1024:
                        raise RouteObservationError('invalid selected route')
                    selections.append('expectedRelay' if chain == expected_proxy_chain else (
                        'direct' if chain == '[direct://]' else 'other'))
            route = 'unobserved' if missing or not selections else (
                selections[0] if len(set(selections)) == 1 else 'mixed')
            counter['selectedRoutes'][route] += 1
    return {'status': 'observation-only', 'destinations': categories,
            'unsupportedRequestLegs': unsupported,
            'dnsTransactionEvents': sum(names[e['type']].startswith('DNS_TRANSACTION') for e in events),
            'udpEvents': sum(names[e['type']].startswith('UDP_') for e in events),
            'successfulSocketRouteVerified': False, 'onWireDNSVerified': False,
            'generalPrivacyQualified': False,
            'scope': 'Default NetLog request legs; selected routes only; destination category does not prove purpose'}
