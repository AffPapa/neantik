#!/usr/bin/env python3
"""Check retained own DNS observations; never launches or upgrades missing data."""
import argparse
import json
from pathlib import Path
import re


def require(condition, reason):
    if not condition: raise ValueError(reason)


def analyze(report, release):
    require(report.get('schemaVersion') == 1 and report.get('status') == 'observed', 'incomplete-producer')
    require(report.get('headed') is True, 'headed-required')
    require(report.get('environment', {}).get('platform') == 'darwin'
            and report['environment'].get('architecture') == 'arm64', 'macos-arm64-required')
    for report_key, value in [('runtimeSHA256', release['runtime']['executableSHA256']),
                              ('frameworkSHA256', release['runtime']['frameworkSHA256']),
                              ('managerSHA256', release['managerSHA256']),
                              ('runtimeVersion', release['runtime']['chromiumVersion']),
                              ('releaseVersion', release['version']), ('releaseBuild', release['build'])]:
        require(report.get(report_key) == value, 'candidate-binding-'+report_key)
    for field in ('runtimeSHA256', 'frameworkSHA256', 'managerSHA256', 'fixtureConfigurationSHA256', 'releaseReportSHA256'):
        require(isinstance(report.get(field), str) and re.fullmatch('[0-9a-f]{64}', report[field]), 'missing-binding')
    require(len(report.get('sourceFiles', {})) == 4 and all(
        isinstance(v, str) and re.fullmatch('[0-9a-f]{64}', v) for v in report['sourceFiles'].values()), 'fixture-source-binding')
    sessions = report.get('sessions')
    require(isinstance(sessions, list) and [s.get('mode') for s in sessions] == ['proxy', 'direct', 'bypass'], 'missing-or-duplicate-session')
    phases = [['proxy-success', 'upstream-cut', 'dns-refused', 'upstream-refused', 'proxy-recovered'],
              ['doh-refused', 'direct-control'], ['bypass-control']]
    rows = {}
    for session, names in zip(sessions, phases):
        require(session.get('status') == 'observed', 'session-incomplete')
        cleanup = session.get('cleanup', {})
        require(cleanup.get('browserExited') is True and type(cleanup.get('ownedProcessesRemaining')) is int
                and cleanup['ownedProcessesRemaining'] == 0, 'owned-processes-unsettled')
        require(session.get('readiness', {}).get('eligibleForAttempt') is True, 'resource-admission')
        require(isinstance(session.get('sessionID'), str) and session['sessionID'], 'missing-session-binding')
        for field in ('profileRootSHA256', 'configurationSHA256'):
            require(isinstance(session.get(field), str) and re.fullmatch('[0-9a-f]{64}', session[field]), 'missing-profile-binding')
        observations = session.get('observations', [])
        require([r.get('phase') for r in observations] == names, 'missing-or-duplicate-phase')
        for row in observations:
            for key in ('udpAnswers', 'udpFailures', 'dohAnswers', 'dohFailures', 'protectedOrigins', 'directOrigins'):
                require(type(row.get(key)) is int and 0 <= row[key] <= 1000, 'invalid-count')
            require(type(row.get('committed')) is bool, 'missing-navigation-state')
            require(row.get('navigationError') is None or isinstance(row['navigationError'], str)
                    and re.fullmatch(r'net::ERR_[A-Z_]+', row['navigationError']), 'unclassified-navigation-failure')
            rows[row['phase']] = row
    require(len({s['sessionID'] for s in sessions}) == 3
            and len({s['profileRootSHA256'] for s in sessions}) == 3, 'session-isolation')
    require(sessions[0].get('establishedStreamCut') is True, 'established-stream-not-cut')
    def success(name, protected):
        row = rows[name]
        require(row['committed'] and row['navigationError'] is None, 'page-not-committed-'+name)
        require(row['protectedOrigins' if protected else 'directOrigins'] > 0
                and row['directOrigins' if protected else 'protectedOrigins'] == 0, 'route-mismatch-'+name)
        require(row['udpAnswers' if protected else 'dohAnswers'] > 0, 'dns-positive-missing-'+name)
        require(row['dohAnswers' if protected else 'udpAnswers'] == 0
                and row['dohFailures' if protected else 'udpFailures'] == 0, 'unexpected-dns-route-'+name)
    for phase in ('proxy-success', 'proxy-recovered'): success(phase, True)
    for phase in ('upstream-cut', 'dns-refused', 'upstream-refused', 'doh-refused'):
        row = rows[phase]
        require(not row['committed'] and row['navigationError'] is not None, 'failed-navigation-not-observed-'+phase)
        require(row['protectedOrigins'] == row['directOrigins'] == 0, 'unexpected-origin-during-failure-'+phase)
    require(rows['dns-refused']['udpFailures'] > 0 and rows['dns-refused']['dohAnswers'] == rows['dns-refused']['dohFailures'] == 0,
            'dns-servfail-or-proxy-boundary-missing')
    require(rows['doh-refused']['dohFailures'] > 0 and rows['doh-refused']['udpAnswers'] == rows['doh-refused']['udpFailures'] == 0,
            'direct-doh-servfail-control-missing')
    success('direct-control', False)
    success('bypass-control', False)
    return dict(schemaVersion=1, status='verified-controlled-dns-slice', actualBrowser=True, actualManagerRelay=False,
        runtimeSHA256=report['runtimeSHA256'], observations=len(rows), sessions=3,
        checks=['owned HTTP destination resolved by upstream UDP', 'DNS SERVFAIL blocks owned origin',
                'established proxy stream cut', 'new requests refused during upstream faults',
                'same proxy session recovers', 'browser Direct DoH positive and SERVFAIL control',
                'intentional proxy bypass detected at owned origin', 'owned processes settled'],
        allNetworkGatesComplete=False,
        limitations=['raw signed runtime only; actual manager/relay integration remains',
                     'own HTTP origins and own loopback UDP/DoH only; no global DNS/UDP absence claim',
                     'self-signed DoH uses scoped SPKI override; not OS-default-trusted HTTPS upstream',
                     'background telemetry, network change and other hardware remain separate'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('observations', type=Path); parser.add_argument('release', type=Path)
    args = parser.parse_args()
    try:
        report = json.loads(args.observations.read_text()); release = json.loads(args.release.read_text())
        result = analyze(report, release)
    except (ValueError, KeyError, TypeError, AttributeError, OSError):
        print(json.dumps({'status': 'not-qualified', 'allNetworkGatesComplete': False})); return 1
    print(json.dumps(result, indent=2)); return 0


if __name__ == '__main__': raise SystemExit(main())
