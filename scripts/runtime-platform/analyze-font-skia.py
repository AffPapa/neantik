#!/usr/bin/env python3
"""Strict analyzer for fixed native Skia cases; models are not native evidence."""
import json
from pathlib import Path

CASES = {
    'collection-query-preflight': {'collectionResolvedExactly'},
    'mixed-restricted-collection': {'ownLookupBehavior', 'enumerationDrawing',
                                  'membershipBoundaryBehavior', 'protectedMemberSeen',
                                  'canaryEnumerationBehavior', 'familyCountBehavior'},
    'own-only-no-global-fallback': {'behavior'},
    'single-member-traits-and-character': {'missingCharacterPrecondition',
                                          'traitsBoundaryBehavior', 'fallbackBoundaryBehavior'},
    'full-protected-family-styles': {'actualStylesSourceAndDrawing'},
    'ui-variable-weight-clones': {'supportedAxisPresent', 'distinctCoordinatesApplied',
                                 'baseSourceAllowed', 'baseProtectedOrigin', 'clonedSourcesAllowed',
                                 'postCloneSourceAllowed', 'actualDrawing',
                                 'repeatedRastersStable', 'distinctRastersDrawn'},
}


def check_observation(value, mode):
    if mode == 'observe':
        if value != dict(schemaVersion=1, observer=True, ownCanaryAbsent=True):
            raise ValueError('fresh cleanup observer failed')
        return dict(status='passed', observer=True)
    if mode not in ('native', 'policy'):
        raise ValueError('unknown native role')
    expected = {'cases', 'complete', 'schemaVersion', 'policy', 'registrationScope',
                'ownCanaryAbsentBefore', 'ownRegistrationRemoved', 'actualSkia',
                'browserQualified'}
    if set(value) != expected or value['schemaVersion'] != 1:
        raise ValueError('unexpected native envelope')
    for key in ('complete', 'ownCanaryAbsentBefore', 'ownRegistrationRemoved', 'actualSkia'):
        if value[key] is not True:
            raise ValueError('native operation or cleanup incomplete')
    if value['policy'] is not (mode == 'policy') or value['browserQualified'] is not False or value['registrationScope'] != 'process':
        raise ValueError('native role/scope mismatch')
    if not isinstance(value['cases'], list) or [row.get('case') for row in value['cases']] != list(CASES):
        raise ValueError('missing, reordered or duplicate native case')
    checks = 0
    for row in value['cases']:
        fields = CASES[row['case']]
        if set(row) != fields | {'case'} or any(row[key] is not True for key in fields):
            raise ValueError('native case behavior failed: ' + row['case'])
        checks += len(fields)
    return dict(status='passed', mode=mode, cases=len(CASES), checks=checks,
                nativeWideningIsSensitiveNegative=mode == 'native',
                scope='actual patched Skia native operations; not headed browser or release qualification')


def check_report(report):
    if report.get('status') != 'observed' or report.get('inputsRechecked') is not True:
        raise ValueError('native stage incomplete or changed')
    if report.get('cleanup') != dict(ownedProcessesRemaining=0, ownedRootsRemaining=0):
        raise ValueError('native stage cleanup incomplete')
    if [row.get('mode') for row in report.get('sessions', [])] != ['native', 'policy', 'observe']:
        raise ValueError('missing native/policy/fresh observer')
    result = []
    for row in report['sessions']:
        if row.get('exitCode') != 0 or row.get('timedOut') is not False or row.get('signal') is not None:
            raise ValueError('native child failed')
        admission = row.get('admission', {})
        if admission.get('exitCode') != 0 or admission.get('readiness', {}).get('eligibleForAttempt') is not True:
            raise ValueError('native child not admitted')
        result.append(check_observation(row['observation'], row['mode']))
    return dict(status='passed', results=result, scope='finite native Skia probe only', releaseQualified=False)


if __name__ == '__main__':
    import sys
    try:
        print(json.dumps(check_report(json.loads(Path(sys.argv[1]).read_text()))))
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        print(json.dumps(dict(status='FAIL', reason='native Skia evidence incomplete', releaseQualified=False)))
        raise SystemExit(1)
