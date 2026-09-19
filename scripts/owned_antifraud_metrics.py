"""Offline shadow-study metrics, not a fraud detector or enforcement engine."""
import argparse
import json
import math
import os
from pathlib import Path
import stat
import sys

COHORTS = ('baseline', 'privacy', 'vpn', 'accessibility')


def require(condition):
    if not condition:
        raise ValueError('Invalid owned-study aggregate; no input contents echoed')


def count(value):
    require(type(value) is int and 0 <= value <= 1_000_000)
    return value


def rate(numerator, denominator):
    if not denominator:
        return {'events': numerator, 'eligible': 0, 'rate': None, 'wilson95': None}
    p = numerator / denominator
    z = 1.959963984540054
    scale = 1 + z*z/denominator
    center = (p + z*z/(2*denominator))/scale
    half = z*math.sqrt(p*(1-p)/denominator + z*z/(4*denominator**2))/scale
    return {'events': numerator, 'eligible': denominator, 'rate': p,
            'wilson95': [max(0, center-half), min(1, center+half)]}


def summarize(document):
    require(isinstance(document, dict) and set(document) ==
            {'schemaVersion', 'mode', 'partition', 'unit', 'labelSource', 'rows', 'identity'})
    require(type(document['schemaVersion']) is int and document['schemaVersion'] == 1)
    require(document['mode'] == 'shadow' and document['partition'] == 'evaluation')
    require(document['unit'] == 'independent-synthetic-profile')
    require(document['labelSource'] == 'independent-scenario-oracle')
    rows = document['rows']
    require(isinstance(rows, list) and 0 < len(rows) <= 48)
    cells = {}
    automation = {'manual': 0, 'automated': 0}
    for row in rows:
        require(isinstance(row, dict) and set(row) == {'cohort', 'automation', 'truth', 'decision', 'count'})
        require(row['cohort'] in COHORTS and row['automation'] in automation)
        require(row['truth'] in ('legitimate', 'abuse') and row['decision'] in ('allow', 'challenge', 'block'))
        key = (row['cohort'], row['automation'], row['truth'], row['decision'])
        require(key not in cells)
        cells[key] = count(row['count'])
        automation[row['automation']] += cells[key]
    cohorts = {}
    for cohort in COHORTS:
        def total(truth, decision=None):
            return sum(n for (c, a, t, d), n in cells.items()
                       if c == cohort and t == truth and (decision is None or d == decision))
        legitimate, abuse = total('legitimate'), total('abuse')
        cohorts[cohort] = {
            'falseChallenge': rate(total('legitimate', 'challenge'), legitimate),
            'falseBlock': rate(total('legitimate', 'block'), legitimate),
            'missedIntervention': rate(total('abuse', 'allow'), abuse),
        }
    identity = document['identity']
    require(isinstance(identity, dict) and set(identity) == {'falseMerge', 'distinctPairs', 'falseSplit', 'samePairs'})
    identity = {key: count(value) for key, value in identity.items()}
    require(identity['falseMerge'] <= identity['distinctPairs'] and identity['falseSplit'] <= identity['samePairs'])
    return {'schemaVersion': 1, 'mode': 'shadow', 'enforcement': 'none',
            'cohorts': cohorts, 'automationCountsNotFraudLabels': automation,
            'identity': {'falseMerge': rate(identity['falseMerge'], identity['distinctPairs']),
                         'falseSplit': rate(identity['falseSplit'], identity['samePairs'])},
            'limitations': ['Input labels, independence and evaluation split are declared, not independently verified.',
                            'Wilson intervals assume independent units; repeated reloads are not new profiles.',
                            'Challenge is an intervention, not proof of detecting abuse.',
                            'Privacy, VPN, accessibility and automation never assign ground truth.']}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--acknowledge-owned-study', action='store_true', required=True)
    args = parser.parse_args()
    try:
        fd = os.open(args.input, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode))
            raw = stream.read(2_000_001)
        require(len(raw) <= 2_000_000)
        report = summarize(json.loads(raw, object_pairs_hook=unique_object))
    except (OSError, ValueError, KeyError, TypeError):
        print('Owned-study validation failed; no input contents echoed.', file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
