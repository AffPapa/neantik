"""HTTP requests, TCP attempts and authenticated tunnels are distinct counts."""


def evaluate(*, event, label, expected_success, responses, tcp, tunnels,
             expected_responses, route, trust_events, expected_trust=None):
    if event.get('case') != label or event.get('success') is not expected_success:
        return False
    if any(type(x) is not int or x < 0 for x in (responses, tcp, tunnels)):
        return False
    if responses != expected_responses:
        return False
    if route == 'relay':
        valid_route = tunnels > 0 and tcp == tunnels
    elif route == 'direct':
        valid_route = tunnels == 0 and tcp >= max(1, responses)
    elif route == 'blocked':
        valid_route = responses == tcp == tunnels == 0
    else:
        raise ValueError('Unknown measured route')
    if expected_trust is not None:
        valid_route = valid_route and bool(trust_events) and all(x is expected_trust for x in trust_events)
    return valid_route
