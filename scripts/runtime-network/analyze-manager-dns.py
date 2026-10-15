#!/usr/bin/env python3
"""Qualify one retained manager/relay DNS observation, never global DNS privacy.

The independent upstream resolver/origin ledger must agree with five live
kernel/metadata custody snapshots. A literal-IP Direct control demonstrates
origin sensitivity while SERVFAIL remains armed; it is not a Direct DNS test.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location('owned_manager_dns_collector', Path(__file__).with_name('collect-manager-dns.py'))
COLLECT = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(COLLECT)
PHASES = COLLECT.PHASES
INPUTS = ('fixture-ledger.json', *(f'dns-custody-{phase}.json' for phase in (*PHASES, 'cleanup')))
HASHES = dict(fixtureSHA256='manager-route-fixture.py', dnsFixtureSHA256='manager-dns-fixture.py',
              dnsWireFixtureSHA256='controlled-dns-fixture.py', collectorSHA256='collect-manager-dns.py')


def require(condition, reason):
    if not condition: raise ValueError(reason)


def integer(value, minimum=0): return type(value) is int and value >= minimum
def number(value): return type(value) in (int, float) and math.isfinite(value) and value >= 0
def hash_value(value): return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def qualify(receipts):
    try:
        ledger = receipts['fixture-ledger.json']; events = ledger['events']
        require(type(events) is list and 0 < len(events) <= 4096, 'empty-or-unbounded-ledger')
        require(ledger['serverThreadsDrained'] is True, 'fixture-not-drained')
        require(ledger['managerExitCode'] == 0 and type(ledger['managerExitCode']) is int, 'manager-exit-not-clean')
        require(type(ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining']) is int
                and ledger['runtimeCleanup']['ownedRuntimeProcessesRemaining'] == 0, 'runtime-not-settled')
        require(all(isinstance(e, dict) and number(e['at']) and isinstance(e['kind'], str) for e in events), 'invalid-events')
        times = [e['at'] for e in events]
        require(times == sorted(times), 'unordered-events')
        controls = [e for e in events if e['kind'] == 'dns-control']
        require(len(controls) == 3, 'missing-or-extra-fault-transitions')
        for event, epoch, enabled in zip(controls, (0, 1, 2), (False, True, False)):
            require(type(event['faultEpoch']) is int and event['faultEpoch'] == epoch
                    and event['faultEnabled'] is enabled and event['controlConsistent'] is True, 'invalid-fault-transition')
        require(controls[0]['at'] < controls[1]['at'] < controls[2]['at'], 'unordered-controls')
        samples = [receipts['dns-custody-' + phase + '.json'] for phase in PHASES]
        baseline, success, refused, direct, recovery = samples
        require(all(s['phase'] == phase and number(s['at']) for s, phase in zip(samples, PHASES)), 'wrong-custody-phase')
        require([s['at'] for s in samples] == sorted(set(s['at'] for s in samples)), 'unordered-custody')
        for s in samples:
            for field in (*HASHES, 'managerSHA256', 'candidateManifestSHA256', 'metadataIdentitySHA256'):
                require(hash_value(s[field]), 'invalid-custody-hash')
                if field != 'metadataIdentitySHA256' or s is not direct:
                    require(s[field] == baseline[field], 'custody-input-changed')
            require(s['manager'] == baseline['manager'], 'manager-generation-changed')
            process(s['manager'])
            require(integer(s['revision']), 'invalid-revision')
            require(s['version'] == baseline['version'] and s['build'] == baseline['build'], 'app-version-changed')
        require(integer(baseline['revision']) and baseline['lastLaunchedAt'] is None, 'invalid-unused-baseline')
        protected = (success, refused, recovery)
        for s in protected:
            require(s['profileID'] == baseline['profileID'] and s['revision'] == baseline['revision'] + 1,
                    'unexpected-profile-revision')
            require(isinstance(s['lastLaunchedAt'], str) and bool(s['lastLaunchedAt'])
                    and s['lastLaunchedAt'] == success['lastLaunchedAt'] and s['updatedAt'] == success['updatedAt'],
                    'unexpected-launch-metadata')
            for key in ('browser', 'relayOwner', 'relay', 'sessionGeneration', 'leaseSHA256', 'configurationSHA256'):
                require(s[key] == success[key], 'protected-session-changed')
            process(s['browser']); process(s['relayOwner'])
            require(s['browser']['parentPID'] == s['relayOwner']['parentPID'] == s['manager']['pid'], 'parent-chain-mismatch')
            relay = s['relay']
            require(relay['profileID'].lower() == s['profileID'] and relay['sessionGeneration'].lower() == s['sessionGeneration'], 'lease-profile-session-mismatch')
            require(relay['configurationSHA256'] == s['configurationSHA256'] == baseline['configurationSHA256'], 'configuration-revision-mismatch')
            require(relay['ownerPID'] == s['relayOwner']['pid'] and relay['ownerStartSeconds'] == s['relayOwner']['startSeconds']
                    and relay['ownerStartMicroseconds'] == s['relayOwner']['startMicroseconds']
                    and relay['ownerUID'] == s['relayOwner']['uid'], 'owner-lease-generation-mismatch')
            require(all(hash_value(relay[k]) for k in ('runtimeExecutableSHA256', 'runtimeFrameworkSHA256')), 'runtime-hash-missing')
        direct_base = baseline['directBaseline']
        process(direct['browser'])
        require(direct['profileID'] == direct_base['profileID'] and direct['profileID'] != baseline['profileID']
                and direct['revision'] == direct_base['revision'] + 1
                and direct['metadataIdentitySHA256'] == direct_base['metadataIdentitySHA256']
                and direct.get('relay') is None and direct['browser']['parentPID'] == baseline['manager']['pid']
                and direct['browser']['pid'] != success['browser']['pid'], 'invalid-direct-control-custody')
        # Accepted answers are linked BEFORE connecting to the origin. UDP
        # send/log scheduling can reverse, so do not order by dns-wire timestamps.
        starts = {}
        resolutions = {}
        peers = {}
        direct_peers = {}
        origins = []
        arrivals = {}
        for e in events:
            kind = e['kind']
            if kind == 'dns-origin-arrival':
                aid = e['arrivalID']
                require(isinstance(aid, str) and re.fullmatch('[0-9a-f]{32}', aid) and aid not in arrivals, 'invalid-or-duplicate-origin-arrival')
                require(type(e['throughOwnedUpstream']) is bool and e['controlConsistent'] is True, 'ambiguous-origin-arrival')
                if not e['throughOwnedUpstream']:
                    require(e['phase'] == 'direct-control', 'unintended-direct-origin-arrival')
                arrivals[aid] = e
                continue
            if kind in ('dns-request-peer', 'dns-direct-peer'):
                expected = direct if kind == 'dns-direct-peer' else success
                target = direct_peers if kind == 'dns-direct-peer' else peers
                rid = e['requestID']
                require(rid not in target and isinstance(rid, str) and re.fullmatch('[0-9a-f]{32}', rid), 'duplicate-or-invalid-peer')
                require(e['manager'] == expected['manager'] and e['browser'] == expected['browser']
                        and e['profileID'] == expected['profileID'] and e['sessionGeneration'] == expected['sessionGeneration']
                        and e['configurationSHA256'] == expected.get('configurationSHA256') and hash_value(e['socketTupleSHA256']),
                        'socket-peer-session-mismatch')
                chain = e['peerChain']
                require(type(chain) is list and 1 <= len(chain) <= 4, 'peer-chain-required')
                for p in chain:
                    process(p); require(p['uid'] == expected['manager']['uid'], 'peer-uid-mismatch')
                if kind == 'dns-request-peer':
                    require(chain == [expected['relayOwner']] and rid in starts and starts[rid]['at'] < e['at'], 'request-not-from-owned-relay')
                else:
                    require(chain[-1] == expected['browser'] and all(a['parentPID'] == b['pid'] for a,b in zip(chain, chain[1:])), 'direct-not-from-owned-browser')
                target[rid] = e
                continue
            if kind not in ('dns-request-begin', 'dns-resolution-accepted', 'dns-resolution-rejected', 'origin', 'origin-stream'):
                continue
            rid = e['requestID']
            require(isinstance(rid, str) and re.fullmatch('[0-9a-f]{32}', rid) is not None, 'request-id-missing')
            require(integer(e['faultEpoch']) and integer(e['requestEpoch']) and type(e['faultEnabled']) is bool
                    and e['controlConsistent'] is True, 'invalid-event-fault')
            if kind == 'dns-request-begin':
                require(rid not in starts and e['requestEpoch'] == e['faultEpoch'], 'duplicate-or-stale-request')
                starts[rid] = e
            elif kind.startswith('dns-resolution-'):
                require(rid in starts and rid not in resolutions and starts[rid]['phase'] == e['phase']
                        and rid in peers and peers[rid]['at'] < e['at']
                        and starts[rid]['at'] < e['at'] and starts[rid]['requestEpoch'] == e['requestEpoch'], 'unlinked-resolution')
                require(type(e['rcode']) is int and e['rcode'] == (0 if kind.endswith('accepted') else 2), 'invalid-resolution-code')
                resolutions[rid] = e
            else:
                arrival = arrivals.get(e['arrivalID'])
                require(arrival is not None and arrival['at'] < e['at'] and arrival['phase'] == e['phase']
                        and arrival['throughOwnedUpstream'] == e['throughOwnedUpstream'], 'origin-arrival-unlinked')
                require(type(e['throughOwnedUpstream']) is bool, 'ambiguous-origin-route')
                if e['throughOwnedUpstream']:
                    answer = resolutions.get(rid)
                    require(answer is not None and answer['kind'] == 'dns-resolution-accepted'
                            and answer['phase'] == e['phase'] and answer['at'] < e['at']
                            and answer['requestEpoch'] == e['requestEpoch'] == e['faultEpoch']
                            and answer['faultEnabled'] == e['faultEnabled'], 'origin-without-accepted-resolution')
                else:
                    require(rid in direct_peers and direct_peers[rid]['at'] < e['at'], 'direct-origin-without-owned-socket')
                require(not any(x['requestID'] == rid for x in origins), 'replayed-origin-request')
                origins.append(e)
        require(len(arrivals) == len(origins) and len({e['arrivalID'] for e in origins}) == len(origins), 'rejected-or-unaccounted-origin-arrival')
        positive = [e for e in origins if e['kind'] == 'origin' and e['phase'] == 'proxy-success' and e['throughOwnedUpstream']]
        recovered = [e for e in origins if e['kind'] == 'origin' and e['phase'] == 'proxy-recovered' and e['throughOwnedUpstream']]
        direct_hits = [e for e in origins if e['kind'] == 'origin' and e['phase'] == 'direct-control' and not e['throughOwnedUpstream']]
        rejected = [e for e in resolutions.values() if e['kind'] == 'dns-resolution-rejected' and e['phase'] == 'dns-refused']
        require(positive and recovered and direct_hits and rejected, 'missing-real-observation')
        fault, reset = controls[1]['at'], controls[2]['at']
        require(all(baseline['at'] < e['at'] <= success['at'] < fault and e['faultEpoch'] == 0 and e['faultEnabled'] is False for e in positive), 'positive-outside-session-window')
        require(all(fault < e['at'] <= refused['at'] and e['faultEpoch'] == e['requestEpoch'] == 1
                    and e['faultEnabled'] is True for e in rejected), 'refusal-outside-window')
        require(all(refused['at'] < e['at'] <= direct['at'] < reset and e['faultEpoch'] == e['requestEpoch'] == 1
                    and e['faultEnabled'] is True for e in direct_hits), 'direct-control-not-during-fault')
        require(min(e['at'] for e in direct_hits) - min(e['at'] for e in rejected) >= 5, 'failure-window-too-short')
        require(all(reset < e['at'] <= recovery['at'] and e['faultEpoch'] == 2 and e['faultEnabled'] is False for e in recovered), 'recovery-outside-window')
        require(not any(fault <= e['at'] < reset and e not in direct_hits for e in origins), 'origin-hit-during-protected-failure')
        require(not any(not e['throughOwnedUpstream'] and e not in direct_hits for e in origins), 'unexpected-direct-origin')
        for phase, code, start, end in [('proxy-success', 0, baseline['at'], fault), ('dns-refused', 2, fault, reset), ('proxy-recovered', 0, reset, recovery['at'])]:
            require(any(e['kind'] == 'dns-wire' and e['phase'] == phase and e['transport'] == 'udp' and e['queryType'] == 1
                        and type(e['rcode']) is int and e['rcode'] == code and e['responseSent'] is True
                        and start < e['at'] <= end for e in events), 'wire-dns-observation-missing')
        cleanup = receipts['dns-custody-cleanup.json']
        require(cleanup['collectorSHA256'] == baseline['collectorSHA256'] and number(cleanup['at']) and cleanup['at'] > recovery['at']
                and type(cleanup['ownedProcessesRemaining']) is int and cleanup['ownedProcessesRemaining'] == 0
                and cleanup['ordinaryInstanceTouched'] is False, 'owned-cleanup-incomplete')
    except (KeyError, TypeError, IndexError, AttributeError):
        raise ValueError('missing-or-malformed-manager-dns-receipt') from None
    return dict(schemaVersion=1, result='scoped-manager-dns-observations-pass',
        checks=['same live manager/browser/relay generation', 'exact markLaunched metadata transition',
                'each request socket belongs to owned relay or owned Direct browser helper',
                'linked upstream UDP DNS and protected origin', 'SERVFAIL and no origin during failure window',
                'literal-IP Direct origin sensitivity while fault armed', 'same-session recovery', 'owned cleanup'],
        runtimeExecutableSHA256=success['relay']['runtimeExecutableSHA256'], runtimeFrameworkSHA256=success['relay']['runtimeFrameworkSHA256'],
        managerSHA256=baseline['managerSHA256'], version=baseline['version'], build=baseline['build'],
        managerDNSScope='Owned upstream DNS only; no OS resolver, global DNS/UDP, existing-stream or Direct DNS claim',
        globalDNSQualified=False, allNetworkGatesComplete=False, releaseGate=False,
        open=['global DNS/UDP', 'background traffic', 'network change', 'default-trusted HTTPS upstream', 'other environments'])


def process(value):
    require(all(integer(value[k], 1) for k in ('pid', 'parentPID', 'startSeconds'))
            and integer(value['uid']) and integer(value['startMicroseconds']) and value['startMicroseconds'] < 1_000_000
            and isinstance(value['cdhash'], str) and re.fullmatch('[0-9a-f]{40}', value['cdhash']), 'invalid-process-identity')


def analyze(directory):
    receipts, hashes = {}, {}
    for name in INPUTS:
        raw = COLLECT.read_private(directory / name)
        receipts[name] = json.loads(raw); hashes[name] = hashlib.sha256(raw).hexdigest()
    result = qualify(receipts)
    baseline = receipts['dns-custody-before-launch.json']
    for key, filename in HASHES.items():
        require(hashlib.sha256(Path(__file__).with_name(filename).read_bytes()).hexdigest() == baseline[key], 'harness-input-changed')
    result.update(inputSHA256=hashes, analyzerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipts', type=Path, required=True)
    args = parser.parse_args()
    try: result = analyze(args.receipts)
    except (ValueError, OSError) as error:
        reason = str(error) if type(error) is ValueError else 'input-read-refused'
        print(json.dumps(dict(result='FAIL', reason=reason, allNetworkGatesComplete=False))); raise SystemExit(1)
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
