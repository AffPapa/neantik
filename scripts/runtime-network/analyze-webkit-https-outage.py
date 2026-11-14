#!/usr/bin/env python3
"""Evaluate the HTTPS refusal window between two attributed WebKit phases."""

import argparse
import json
from pathlib import Path


def evaluate(before, during, recovery, *, route):
    """Join three snapshots from the same fixture. Browser custody is separate."""
    if route not in ('A', 'B'):
        raise ValueError('invalid-proxy-route')
    if any(sample.get('originRouteAttribution') is not True for sample in (before, during, recovery)):
        raise ValueError('request-attribution-required')

    def counter(sample, group, name):
        value = sample[group][name]
        if type(value) is not int or value < 0:
            raise ValueError('invalid-counter')
        return value

    proxy = f'proxy{route}'
    if counter(during, proxy, 'refused') <= counter(before, proxy, 'refused'):
        raise ValueError('proxy-refusal-not-observed')
    if counter(during, 'origin', 'accepted') != counter(before, 'origin', 'accepted'):
        raise ValueError('origin-connection-during-refusal')
    if counter(during, proxy, 'authenticated') != counter(before, proxy, 'authenticated'):
        raise ValueError('proxy-tunnel-succeeded-during-refusal')
    if any(counter(sample, 'origin', 'unattributedConnections') for sample in (before, during, recovery)):
        raise ValueError('unattributed-origin-connection')

    earlier, outage, later = (sample['origin']['requestTrace'] for sample in (before, during, recovery))
    if not all(isinstance(trace, list) for trace in (earlier, outage, later)):
        raise ValueError('invalid-origin-trace')
    if earlier != outage or later[:len(outage)] != outage:
        raise ValueError('origin-trace-changed-during-refusal')
    if counter(recovery, proxy, 'authenticated') <= counter(during, proxy, 'authenticated'):
        raise ValueError('proxy-tunnel-did-not-recover')
    tail = later[len(outage):]
    if not any(event.get('category') == 'page' and event.get('result') == 'responded' for event in tail):
        raise ValueError('recovery-page-missing')
    if any(event.get('route') != route for event in tail):
        raise ValueError('unexpected-recovery-route')
    return {'status': 'PASS', 'scope': 'fixture HTTPS refusal and attributed recovery',
            'route': route, 'browserCustodyVerified': False, 'releaseQualified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--route', required=True, choices=('A', 'B'))
    parser.add_argument('snapshots', nargs=3, type=Path, metavar='SNAPSHOT')
    args = parser.parse_args()
    try:
        reports = [json.loads(path.read_bytes()) for path in args.snapshots]
        if any(report['status'] != 'snapshot' for report in reports):
            raise ValueError('fixture-snapshot-required')
        result = evaluate(*(report['counts'] for report in reports), route=args.route)
    except (OSError, KeyError, TypeError, AttributeError, ValueError) as error:
        parser.exit(1, f'HTTPS outage evidence refused ({type(error).__name__}).\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
