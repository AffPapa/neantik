#!/usr/bin/env python3
"""Check retained CoreText primitive evidence offline; no browser qualification.

Exit success needs actual drawing, a selected/rejected name collision, seven
shaped samples and process-only cleanup. Aggregate PASS flags alone never pass.
"""
import argparse
import hashlib
import json
from pathlib import Path

SOURCES = (
    'runtime/font-policy-v1/system_font_source.h',
    'runtime/font-policy-v1/system_font_source_variations.cc',
    'scripts/runtime-platform/probe-font-origin.mm',
    'scripts/runtime-platform/make-font-policy-canary.py',
    'scripts/runtime-platform/run-font-origin-probe.py',
    'scripts/runtime-platform/requirements-font-qa.txt',
    'scripts/native-qa-readiness.py',
)
SAMPLES = ('Latin', 'Cyrillic', 'CJK', 'Arabic', 'Combining', 'ColourEmoji', 'VariationSelector')
CONTROLS = (
    'canaryAbsentBeforeRegistration', 'canaryRegistered', 'canaryResolvedByNativeLookup',
    'canaryDrawn', 'canaryRejectedByHostPolicy', 'familyCollisionRegistered',
    'nativeFamilyLookupSelectedOwnCollision', 'actualFamilyCollisionControlRejected',
    'systemFamilyResultAllowed', 'protectedFamilyCounterpartFound',
    'actualLastResortControlRejected', 'spoofUsesOwnCanaryGlyphs', 'spoofRejected',
    'explicitResourceDataDrawn', 'cacheWithinBound', 'ownRegistrationsRemoved',
    'primitiveControlsPassed', 'candidateFallbackReady',
    'protectedDescriptorCopyConsistent', 'coverageAcceptsProtectedGlyph',
    'nativeFamilyFallbackRecovered', 'coverageRejectsOwnAndLastResort',
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(observation, receipt, readiness):
    issues = []

    def need(value, label):
        if not value:
            issues.append(label)

    try:
        need(observation['schemaVersion'] == 1 and receipt['schemaVersion'] == 1, 'schema')
        need(receipt['status'] == 'native-primitive-complete' and receipt['exitCode'] == 0, 'native-exit')
        need(receipt['actualBrowser'] is False and receipt['productionFilesChanged'] is False, 'scope')
        need(set(receipt['sourceSHA256']) == set(SOURCES), 'source-inventory')
        need(readiness['eligibleForAttempt'] is True and readiness['memoryPressure'] == 1 and
             readiness['thermalState'] == 0 and not readiness['reasons'], 'native-admission')
        need(observation['registrationScope'] == 'process' and observation['systemFontInstallation'] is False, 'registration-scope')
        for key in CONTROLS:
            need(observation[key] is True, key)
        need(observation['nativeFamilyLookupAllowedAfterCollision'] is False, 'collision-must-be-denied')
        need(observation['systemFamilyOriginClass'] == 'protected-system-file', 'positive-origin')
        need(observation['cachedAllowedReads'] == 10000, 'cache-exercised')
        need(type(observation['protectedDescriptorCount']) is int and observation['protectedDescriptorCount'] > 0, 'protected-catalog')
        rows = observation['restrictedSamples']
        need([row['sample'] for row in rows] == list(SAMPLES), 'complete-ordered-samples')
        for row in rows:
            label = row['sample']
            need(row['shapingCompleted'] is True and row['actualBitmapDrawn'] is True, label+':real-draw')
            need(row['missingGlyph'] is False and row['lastResortUsed'] is False, label+':real-glyphs')
            need(type(row['glyphs']) is int and row['glyphs'] > 0, label+':glyph-count')
            need(type(row['distinctGlyphCount']) is int and row['distinctGlyphCount'] > (1 if label == 'CJK' else 0), label+':distinct-glyphs')
            need(row['strictPolicyRejectedRuns'] == 0 and set(row['originClasses']) == {'protected-system-file'} and
                 type(row['originClasses']['protected-system-file']) is int and row['originClasses']['protected-system-file'] > 0, label+':protected-runs')
    except (KeyError, TypeError, ValueError):
        issues.append('missing-or-malformed-evidence')
    return {'passed': not issues, 'issues': issues, 'actualBrowser': False,
            'scope': 'CoreText development primitive only'}


def verify_directory(directory):
    observation = json.loads((directory/'observations.json').read_text())
    receipt = json.loads((directory/'receipt.json').read_text())
    readiness = json.loads((directory/'readiness.json').read_text())
    result = verify(observation, receipt, readiness)
    expected = {'observationsSHA256': directory/'observations.json',
                'binarySHA256': directory/'font-origin-probe'}
    for key, path in expected.items():
        if not path.is_file() or sha256(path) != receipt.get(key):
            result['issues'].append(key+':mismatch')
    for index, source in enumerate(SOURCES):
        path = directory/f'{index}-{Path(source).name}'
        if not path.is_file() or sha256(path) != receipt['sourceSHA256'].get(source):
            result['issues'].append(source+':retained-source-mismatch')
    result['passed'] = not result['issues']
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    try:
        result = verify_directory(args.directory)
    except (OSError, KeyError, ValueError, TypeError):
        result = {'passed': False, 'issues': ['unreadable-or-malformed-evidence'], 'actualBrowser': False}
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
