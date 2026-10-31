#!/usr/bin/env python3
"""Offline proof of one optional proxy-context commit before markLaunched.

The private witness contains ONLY an owned fixture profile. It does not amend
the original custody receipts. Both complete metadata digests must reconstruct
exactly; removing arbitrary identity fields or tolerating revision drift is not
permitted. This is a harness-model correction, not a browser qualification.
"""
import argparse
import copy
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

SPEC = importlib.util.spec_from_file_location('dns_transition_collector', Path(__file__).with_name('collect-manager-dns.py'))
COLLECT = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(COLLECT)
CONTEXT = ('timezoneIdentifier', 'localeIdentifier', 'proxyContextEvidence')


def require(condition, reason):
    if not condition: raise ValueError('preflight-transition-' + reason)


def receipt_hashes(receipts):
    return {name: COLLECT.sha(COLLECT.canonical(value)) for name, value in receipts.items()}


def date(value):
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z', value), 'invalid-date')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def validate(witness, receipts):
    """Return the proven prepared revision/config; no trusted PASS flags."""
    try:
        require(type(witness) is dict and set(witness) == {
            'schemaVersion', 'mode', 'sourceMetadataSHA256', 'receiptCanonicalSHA256', 'selectedProfile'}, 'shape')
        require(type(witness['schemaVersion']) is int and witness['schemaVersion'] == 1
                and witness['mode'] == 'absent-context-preflight-then-launch', 'mode')
        require(isinstance(witness['sourceMetadataSHA256'], str)
                and re.fullmatch('[0-9a-f]{64}', witness['sourceMetadataSHA256']), 'source-hash')
        require(witness['receiptCanonicalSHA256'] == receipt_hashes(receipts), 'receipt-binding')
        baseline = receipts['dns-custody-before-launch.json']
        protected = [receipts['dns-custody-' + phase + '.json'] for phase in ('proxy-success', 'dns-refused', 'proxy-recovered')]
        success = protected[0]; profile = witness['selectedProfile']
        require(type(profile) is dict and profile['name'] == 'QA route proxy'
                and profile['id'].lower() == baseline['profileID'], 'owned-profile')
        require(type(baseline['revision']) is int and type(profile['revision']) is int
                and profile['revision'] == baseline['revision'] + 2, 'revision')
        for sample in protected:
            require(sample['profileID'] == profile['id'].lower() and sample['revision'] == profile['revision']
                    and sample['updatedAt'] == profile['updatedAt']
                    and sample['lastLaunchedAt'] == profile['lastLaunchedAt']
                    and COLLECT.metadata_identity(profile) == sample['metadataIdentitySHA256'], 'post-metadata')
        identity = profile['identity']
        require(type(identity) is dict and all(key in identity for key in CONTEXT), 'missing-context')
        context = identity['proxyContextEvidence']
        require(type(context) is dict and set(context) == {'source', 'observedAt'}
                and context['source'] in ('ipapi.co', 'ipwho.is+freeipapi.com'), 'context-evidence')
        require(isinstance(identity['timezoneIdentifier'], str), 'timezone')
        try: ZoneInfo(identity['timezoneIdentifier'])
        except (ValueError, ZoneInfoNotFoundError): raise ValueError('preflight-transition-timezone') from None
        require(isinstance(identity['localeIdentifier'], str)
                and re.fullmatch('[a-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*', identity['localeIdentifier']), 'locale')
        require(date(baseline['updatedAt']) <= date(context['observedAt']) <= date(success['lastLaunchedAt'])
                and date(success['lastLaunchedAt']) == date(success['updatedAt']), 'time-window')
        reconstructed = copy.deepcopy(profile)
        for key in CONTEXT: del reconstructed['identity'][key]
        require(COLLECT.metadata_identity(reconstructed) == baseline['metadataIdentitySHA256'], 'baseline-metadata')
        reconstructed['revision'] = baseline['revision']
        require(COLLECT.configuration_digest(reconstructed) == baseline['configurationSHA256'], 'baseline-config')
        reconstructed['revision'] += 1
        prepared = COLLECT.configuration_digest(reconstructed)
        require(all(sample['configurationSHA256'] == sample['relay']['configurationSHA256'] == prepared
                    for sample in protected), 'prepared-config')
        return dict(revision=profile['revision'], configurationSHA256=prepared,
                    metadataIdentitySHA256=success['metadataIdentitySHA256'])
    except (KeyError, TypeError, AttributeError, OverflowError):
        raise ValueError('preflight-transition-malformed') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--receipts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    state, root = COLLECT.owned_state(args.state)
    raw = COLLECT.read_private(root / 'manager-data/profiles.json')
    profiles = json.loads(raw)
    require(type(profiles) is list and len(profiles) == 2
            and {p['id'].lower() for p in profiles} == {p['id'].lower() for p in state['profiles']}, 'fixture-metadata')
    names = ('fixture-ledger.json', *(f'dns-custody-{phase}.json' for phase in (*COLLECT.PHASES, 'cleanup')))
    receipts = {name: COLLECT.load(args.receipts / name) for name in names}
    selected = [p for p in profiles if p['id'].lower() == receipts['dns-custody-before-launch.json']['profileID']]
    require(len(selected) == 1, 'selected-profile')
    witness = dict(schemaVersion=1, mode='absent-context-preflight-then-launch',
                   sourceMetadataSHA256=hashlib.sha256(raw).hexdigest(),
                   receiptCanonicalSHA256=receipt_hashes(receipts), selectedProfile=selected[0])
    validate(witness, receipts)
    COLLECT.write_new(args.output, witness)
    print(json.dumps(dict(result='offline-transition-reconstructed', nativeRerun=False,
                          witnessSHA256=COLLECT.sha(args.output.read_bytes()))))


if __name__ == '__main__': main()
