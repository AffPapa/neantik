#!/usr/bin/env python3
"""Join owned Chromium page, proxy and process observations from one QA run."""

import argparse
import json
from pathlib import Path
import re

from importlib import import_module

CORE = import_module('collect-manager-dns')
PHASES = (
    ('fresh', 'browser-page-observed', 'A'),
    ('refused', ('browser-navigation-refused', 'fixture-refusal-page-observed'), 'refused'),
    ('recovered', 'browser-page-observed', 'A'),
    ('reopened', 'browser-page-observed', 'A'),
    ('webrtc', 'browser-webrtc-gathering-completed', 'A'),
)
COUNTERS = ('A', 'B', 'direct', 'refused', 'preflight')


def evaluate(run):
    first = run['firstLaunch']
    reopened = run['reopened']
    require = CORE.require
    for key in ('candidateArchiveSHA256', 'candidateReceiptSHA256', 'profileID',
                'browserData', 'manager', 'browserExecutableSHA256'):
        require(first[key] == reopened[key], 'profile-or-candidate-changed')
    require(re.fullmatch(r'[0-9a-f]{64}', first['candidateArchiveSHA256']) is not None,
            'invalid-candidate-hash')
    require(first['status'] == reopened['status'] == 'observed', 'custody-observation-required')

    def generation(browser):
        values = tuple(browser[key] for key in ('pid', 'startSeconds', 'startMicroseconds'))
        require(all(type(value) is int for value in values)
                and values[0] > 1 and values[1] > 0 and 0 <= values[2] < 1_000_000,
                'invalid-browser-generation')
        return values

    require(generation(first['browser']) != generation(reopened['browser'])
            and first['leaseSHA256'] != reopened['leaseSHA256'], 'browser-did-not-reopen')
    for label, custody in (('firstStop', first), ('finalStop', reopened)):
        stop = run[label]
        require(stop['browserGeneration'] == custody['browser'] and stop['profileID'] == custody['profileID']
                and stop['candidateArchiveSHA256'] == custody['candidateArchiveSHA256']
                and stop['generationAbsent'] is True and stop['profileState'] == 'stopped',
                'owned-browser-stop-unverified')

    def counts(snapshot):
        values = snapshot['counts']
        require(snapshot['status'] == 'snapshot' and set(values) == set(COUNTERS)
                and all(type(value) is int and value >= 0 for value in values.values()),
                'invalid-proxy-snapshot')
        return values

    phases = run['phases']
    require([phase['name'] for phase in phases] == [phase[0] for phase in PHASES],
            'unexpected-phase-order')
    previous = None
    for (name, status, hit), phase in zip(PHASES, phases):
        custody = reopened if name in ('reopened', 'webrtc') else first
        observation = phase['page']
        require(observation['candidateArchiveSHA256'] == custody['candidateArchiveSHA256']
                and observation['profileID'] == custody['profileID']
                and observation['browserGeneration'] == custody['browser'], 'page-custody-mismatch')
        if name == 'refused':
            require(observation['status'] in status, 'refusal-not-observed')
        elif name == 'webrtc':
            require(observation['status'] == status, 'webrtc-gathering-not-observed')
        else:
            require(observation['status'] == status and observation['storage'] ==
                    ('fresh' if name == 'fresh' else 'restored'), 'storage-marker-mismatch')
        before, after = phase['before'], phase['after']
        require(before['refusing'] is (name == 'refused') and after['refusing'] is before['refusing'],
                'refusal-state-changed')
        a, b = counts(before), counts(after)
        require(previous is None or previous == a, 'unattributed-between-phase-activity')
        delta = {key: b[key] - a[key] for key in COUNTERS}
        require(all(value >= 0 for value in delta.values()) and delta[hit] > 0
                and all(delta[key] == 0 for key in COUNTERS if key not in (hit, 'preflight')),
                'unexpected-proxy-or-direct-activity')
        previous = b
    require(counts(run['afterFinalStop']) == previous, 'activity-after-last-page')
    require(run['stunCanary'] == dict(canaryAcknowledged=True, canaryCount=1,
                                     resetVerified=True, countAfterReset=0), 'stun-control-missing')
    require(run['afterFinalStop']['udp'] == {'requests': 0, 'invalid': 0},
            'direct-or-unclassified-stun-packet')
    terminal = run['fixtureTerminal']
    require(terminal['status'] == 'fixture-stopped' and terminal['stunDrained'] is True,
            'fixture-shutdown-unverified')
    require(terminal['counts'] == previous, 'late-http-activity-during-shutdown')
    require(terminal['udp'] == {'requests': 0, 'invalid': 0}, 'late-or-unclassified-stun-packet')
    return {'status': 'PASS', 'scope': 'owned Chromium QA HTTP route, storage and main process lifecycle',
            'webrtc': 'ICE gathering completed; zero packets observed at the owned IPv4 loopback STUN listener',
            'candidateArchiveSHA256': first['candidateArchiveSHA256'],
            'releaseQualified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path, help='Owner-only JSON containing one run and its observations')
    args = parser.parse_args()
    try:
        print(json.dumps(evaluate(CORE.load(args.run))))
    except (OSError, KeyError, TypeError, ValueError) as error:
        parser.exit(1, f'Chromium QA evidence refused ({type(error).__name__}).\n')


if __name__ == '__main__':
    main()
