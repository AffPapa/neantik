#!/usr/bin/env python3
"""Analyze retained owned-route receipts without rerunning a browser.

This verifies one HTTP/TCP observation and its Direct sensitivity control.
It never qualifies DNS, HTTPS upstream, graceful close or all release gates.
Private input filenames/contents do not enter the compact output.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

INPUTS = ('fixture-ledger.json', 'owned-browser-launch.json', 'active-cut-receipt.json',
          'after-cut-counts.json', 'recovery-counts.json', 'direct-negative-control.json', 'cleanup.json')


def qualify(receipts):
    """Fail on missing, stale or contradictory measurements; no vacuous PASS."""
    def require(condition, reason):
        if not condition:
            raise ValueError(reason)
    try:
        ledger, launch, cut, after, recovery, direct, cleanup = (receipts[name] for name in INPUTS)
        for value, fields in ((cleanup, ('ownedProcessesRemaining',)),
                              (cut, ('channelsCut', 'runtimePID')),
                              (after, ('activeChannelsCut', 'upstreamTCPCutAttempts', 'cutPhaseOriginHits', 'directOriginHits')),
                              (recovery, ('recoveredProxyHits', 'directRecoveryHits', 'runtimePID')),
                              (direct, ('originHitsDuringProtectedFailure', 'originHitsWithIntentionalDirectControl'))):
            require(all(type(value[field]) is int and value[field] >= 0 for field in fields), 'invalid-counter')
        for value, field in ((cut, 'streamAgeAtCutSeconds'), (after, 'afterCutSeconds')):
            require(type(value[field]) in (int, float) and math.isfinite(value[field]), 'invalid-duration')
        require(ledger['serverThreadsDrained'] is True, 'fixture-not-drained')
        require(cleanup['ownedProcessesRemaining'] == 0 and cleanup['ordinaryInstanceTouched'] is False, 'cleanup-unverified')
        require(launch['headedShippingManager'] is True, 'headed-launch-required')
        processes = launch['runtimeProcesses']
        require(len(processes) == 1, 'single-bound-runtime-required')
        process = processes[0]
        for flag in ('mockKeychain', 'ownedData', 'proxyConfigured', 'loopbackBypassDisabled'):
            require(process[flag] is True, 'launch-boundary-' + flag)
        require(process['credentialsInArgv'] is False, 'credentials-in-argv')
        require(type(process['pid']) is int and process['pid'] > 0, 'runtime-pid-required')
        require(process['pid'] == cut['runtimePID'] == recovery['runtimePID'], 'session-receipt-mismatch')
        require(cut['protectedFreshStreamBeforeCut'] is True and cut['channelsCut'] >= 2, 'live-cut-not-observed')
        require(0 <= cut['streamAgeAtCutSeconds'] < 30, 'expired-stream')
        require(after['activeChannelsCut'] >= 2 and after['upstreamTCPCutAttempts'] > 0, 'failure-not-observed')
        require(after['cutPhaseOriginHits'] == 0 and after['directOriginHits'] == 0, 'failure-bypassed-proxy')
        require(after['afterCutSeconds'] >= 5, 'failure-window-too-short')
        require(recovery['recoveredProxyHits'] > 0 and recovery['directRecoveryHits'] == 0, 'recovery-not-protected')
        require(direct['sameCanaryReachableDirect'] is True and direct['upstreamStillCut'] is True,
                'negative-control-not-active')
        require(direct['originHitsDuringProtectedFailure'] == 0 and direct['originHitsWithIntentionalDirectControl'] > 0,
                'negative-control-not-sensitive')
        events = ledger['events']
        require(isinstance(events, list) and bool(events), 'empty-ledger')
        times = [event['at'] for event in events]
        require(all(type(t) in (int, float) and math.isfinite(t) for t in times), 'invalid-ledger-time')
        require(times == sorted(times), 'unordered-ledger')
        for event in events:
            if event['kind'] == 'cut-active-local-channels':
                require(type(event['channels']) is int and event['channels'] >= 0, 'invalid-cut-counter')
            if event['kind'] in ('origin', 'origin-stream'):
                require(type(event['throughOwnedUpstream']) is bool, 'ambiguous-route')
        origins = [event for event in events if event['kind'] == 'origin']
        require(any(e['phase']=='proxy-success' and e['throughOwnedUpstream'] for e in origins), 'success-origin-missing')
        require(not any(e['phase']=='upstream-cut' and e['throughOwnedUpstream'] for e in origins), 'protected-failure-hit-origin')
        cuts = [e for e in events if e['kind']=='cut-active-local-channels' and e['channels'] >= 2]
        require(bool(cuts), 'established-cut-missing')
        active = cuts[0]
        require(any(e['kind']=='origin-stream' and e['throughOwnedUpstream'] and e['phase']=='proxy-success'
                    and 0 <= active['at'] - e['at'] < 30 for e in events), 'fresh-stream-missing')
        recovered = next((e for e in origins if e['phase']=='proxy-recovered' and e['throughOwnedUpstream']
                          and e['at'] > active['at']), None)
        require(recovered is not None, 'recovery-origin-missing')
        require(any(e['kind']=='upstream-tcp-cut' and active['at'] <= e['at'] < recovered['at'] for e in events),
                'no-failed-tcp-attempt')
        require(not any(active['at'] <= e['at'] < recovered['at'] for e in origins), 'origin-hit-during-outage')
        negative = next((e for e in origins if e['phase']=='upstream-cut' and not e['throughOwnedUpstream']
                         and e['at'] > recovered['at']), None)
        require(negative is not None and any(e['kind']=='cut-active-local-channels'
                and recovered['at'] < e['at'] <= negative['at'] for e in events), 'direct-control-without-new-cut')
    except (KeyError, TypeError, IndexError, AttributeError):
        raise ValueError('missing-or-malformed-receipt') from None
    return dict(schemaVersion=1, result='scoped-observations-pass',
                checks=['headed owned launch', 'HTTP route', 'established TCP cut',
                        'outage origin isolation', 'HTTP recovery', 'Direct sensitivity control', 'owned cleanup'],
                majorReleaseGate=False, gracefulCloseQualified=False,
                limitation='Retained receipts and ledger; not fresh runtime execution or complete network qualification',
                open=['DNS', 'HTTPS upstream with default trust', 'WebRTC exceptions',
                      'background traffic', 'network change', 'graceful close'])


def analyze(directory):
    receipts, hashes = {}, {}
    for name in INPUTS:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 2_000_000:
            raise ValueError('missing-or-unbounded-input')
        raw = path.read_bytes()
        hashes[name] = hashlib.sha256(raw).hexdigest()
        try: receipts[name] = json.loads(raw)
        except (ValueError, UnicodeError): raise ValueError('invalid-json') from None
    result = qualify(receipts)
    result['inputSHA256'] = hashes
    result['analyzerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipts', type=Path, required=True)
    args = parser.parse_args()
    try: result = analyze(args.receipts)
    except (ValueError, OSError) as error:
        # No paths or offending contents in failure output.
        reason = str(error) if isinstance(error, ValueError) else 'input-read-refused'
        print(json.dumps(dict(result='FAIL', reason=reason, majorReleaseGate=False)))
        raise SystemExit(1)
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
