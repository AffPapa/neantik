#!/usr/bin/env python3
"""Verify retained, private headed HTTPS observations; never issue requests.

The ordinary Chrome reference supplies per-path header availability, not values.
Every available value must match that realm's JS; an absent operation is failure.
"""
import copy
import hashlib
import json
from pathlib import Path
import re
import sys

HEADERS = ('user-agent', 'accept-language', 'sec-ch-ua', 'sec-ch-ua-mobile',
           'sec-ch-ua-platform', 'sec-ch-ua-arch', 'sec-ch-ua-bitness',
           'sec-ch-ua-platform-version', 'sec-ch-ua-full-version-list',
           'sec-ch-device-memory', 'device-memory')
HIGH = HEADERS[5:]
OPERATIONS = ('page', 'redirect', 'cross', 'cross-redirect', 'cross-not-delegated',
              'worker', 'worker-cross', 'service-worker')
MODES = ('chrome-reference', 'unconfigured', 'configured', 'direct-negative')
SOURCES = ('runtime-platform/run-https-identity.mjs',
           'runtime-platform/fixtures/https-identity-fixture.mjs',
           'runtime-platform/fixtures/https-identity-probe.mjs',
           'runtime-platform/fixtures/qa-browser-environment.mjs',
           'runtime-network/run-controlled-dns.mjs')
DIGEST = re.compile(r'^[0-9a-f]{64}$')


def brands(value):
    if not isinstance(value, str):
        return None
    pattern = r'("(?:[^"\\]|\\.)*");v=("(?:[^"\\]|\\.)*")'
    result, end = [], 0
    for match in re.finditer(pattern, value):
        if value[end:match.start()].strip() not in ('', ','):
            return None
        result.append({'brand': json.loads(match[1]), 'version': json.loads(match[2])})
        end = match.end()
    return result if result and not value[end:].strip() else None


def string(value):
    try:
        return json.loads(value) if isinstance(value, str) else None
    except ValueError:
        return None


def identity_issues(js, headers, availability=None):
    """Separate values from availability; complete explicit null keys required."""
    issues = []
    if not isinstance(js, dict) or not isinstance(headers, dict) or set(headers) != set(HEADERS):
        return ['missing-identity']
    if not js.get('userAgent') or headers['user-agent'] != js['userAgent']:
        issues.append('UA')
    languages = js.get('languages')
    parsed = [x.split(';')[0].strip() for x in (headers.get('accept-language') or '').split(',')]
    if not isinstance(languages, list) or not languages or parsed[:len(languages)] != languages:
        issues.append('languages')
    hints = js.get('hints', {})
    memory = js.get('deviceMemory')
    if type(memory) not in (int, float) or memory not in (2, 4, 8, 16, 32):
        issues.append('memory-value')
    for key in HEADERS[2:]:
        value = headers[key]
        if availability is not None and (value is not None) != availability.get(key):
            issues.append('availability:' + key)
        if value is None:
            continue
        if key in ('device-memory', 'sec-ch-device-memory'):
            correct = value == str(memory)
        elif key == 'sec-ch-ua':
            correct = brands(value) == hints.get('brands') and bool(hints.get('brands'))
        elif key == 'sec-ch-ua-full-version-list':
            correct = brands(value) == hints.get('fullVersionList') and bool(hints.get('fullVersionList'))
        elif key == 'sec-ch-ua-mobile':
            correct = type(hints.get('mobile')) is bool and value == ('?1' if hints['mobile'] else '?0')
        else:
            field = {'sec-ch-ua-platform':'platform', 'sec-ch-ua-arch':'architecture',
                     'sec-ch-ua-bitness':'bitness', 'sec-ch-ua-platform-version':'platformVersion'}[key]
            correct = bool(hints.get(field)) and string(value) == hints[field]
        if not correct:
            issues.append('value:' + key)
    return issues


def verify(report, release, reference):
    issues, checks = [], 0
    def need(condition, key):
        nonlocal checks
        checks += 1
        if not condition:
            issues.append(key)
    try:
        need(report['schemaVersion'] == 1 and report['status'] == 'observed', 'producer-complete')
        need(report['environment']['headed'] is True and report['environment']['architecture'] == 'arm64', 'headed-environment')
        need(report['cleanup'] == {'fixtureClosed':True, 'temporaryTLSKeyRemoved':True}, 'fixture-cleanup')
        need(report['runtime'] == {'version':release['runtime']['chromiumVersion'], 'executableSHA256':release['runtime']['executableSHA256'], 'frameworkSHA256':release['runtime']['frameworkSHA256']}, 'published-runtime')
        need(report['managerSHA256'] == release['managerSHA256'] and report['releaseVersion'] == release['version'] and report['releaseBuild'] == release['build'], 'published-app')
        need(all(report['reference'].get(k) == reference[k] for k in ('version','executableSHA256','frameworkSHA256')), 'ordinary-reference')
        need(set(report['sources']) == set(SOURCES) and all(DIGEST.fullmatch(x) for x in report['sources'].values()), 'source-provenance')
        need(report.get('runtimeHashesRechecked') is True, 'runtime-post-check')
        sessions = report['sessions']
        need([x['mode'] for x in sessions] == list(MODES), 'complete-session-matrix')
        need(len({x['id'] for x in sessions}) == 4, 'session-isolation')
        admissions = report['admissionAttempts']
        need([x['mode'] for x in admissions] == list(MODES) and all(x['exitCode'] == 0 and x['readiness']['eligibleForAttempt'] is True for x in admissions), 'native-admission')
        baseline = {r['operation']: r for r in sessions[0]['result']['rows']}
        availability = {op:{k:baseline[op]['http']['headers'][k] is not None for k in HEADERS[2:]} for op in OPERATIONS}
        for session in sessions:
            mode = session['mode']; prefix = mode + ':'
            need(session['status'] == 'observed' and session['headed'] is True and session['documentConfirmed'] is True, prefix+'browser-complete')
            cleanup = session['cleanup']
            need(cleanup['browserExited'] is True and cleanup['gracefulBrowserClose'] is True and cleanup['exitCode'] == 0 and cleanup['ownedProcessesRemaining'] == 0, prefix+'cleanup')
            expected_runtime = reference if mode == 'chrome-reference' else report['runtime']
            need(session['runtimeVersion'] == expected_runtime['version'] and session['runtimeSHA256'] == expected_runtime['executableSHA256'] and session['frameworkSHA256'] == expected_runtime['frameworkSHA256'], prefix+'runtime-binding')
            need(session['profileSeed'] == ('21' if mode in ('configured','direct-negative') else None), prefix+'configuration')
            result = session['result']
            need(not result.get('error') and result['unregistered'] is True and result['crossWarm'] is True and result['secureContext'] is True, prefix+'operations-complete')
            rows = result['rows']
            need([r['operation'] for r in rows] == list(OPERATIONS)+['negative-language'], prefix+'exact-operations')
            need(len({r['nonce'] for r in rows}) == len(rows), prefix+'unique-nonces')
            receipts = session['receipts']; by_id = {r['id']:r for r in receipts}
            need(len(by_id) == len(receipts), prefix+'unique-wire-receipts')
            connects = {x['id']:x for x in session['connects']}
            need(len(connects) == len(session['connects']), prefix+'unique-connects')
            if mode == 'direct-negative':
                need(not connects, prefix+'no-proxy-CONNECTs')
            def custody_valid(value):
                return (isinstance(value,dict) and value.get('sameProcessGroup') is True
                        and value.get('runtimePathBound') is True
                        and bool(DIGEST.fullmatch(value.get('generationSHA256',''))))
            def wire_valid(wire, role, key):
                need(wire.get('sessionID') == session['id'] and wire.get('role') == role, key+':origin-session')
                need(wire.get('tls') is True and wire.get('protocol') in ('TLSv1.2','TLSv1.3'), key+':actual-TLS')
                link = connects.get(wire.get('connectID'), {})
                custody = wire.get('browserCustody')
                if mode == 'direct-negative':
                    route = (wire.get('throughProxy') is False and wire.get('connectID') is None
                             and custody is None and custody_valid(wire.get('directBrowserCustody')))
                else:
                    route = (wire.get('throughProxy') is True and link.get('role') == role
                             and link.get('sessionID') == session['id']
                             and link.get('browserCustody') == custody and custody_valid(custody)
                             and wire.get('directBrowserCustody') is None)
                need(route, key+(':explicit-browser-Direct' if mode=='direct-negative' else ':browser-CONNECT-TLS-custody'))
                return route
            page_js = rows[0]['js']; route_failures = 0
            for row in rows:
                op = row['operation']; key = prefix+op
                wire = by_id.get(row['http']['receiptID'], {})
                need(wire.get('path') == '/identity' and wire.get('nonce') == row['nonce'] == row['http']['nonce'] and wire.get('operation') == op == row['http']['operation'] and wire.get('sessionID') == session['id'] and wire.get('headers') == row['http']['headers'], key+':independent-wire')
                role = 'b' if op in ('cross','cross-redirect','cross-not-delegated','worker-cross') else 'a'
                route = wire_valid(wire, role, key)
                route_failures += not route
                need(row['js'] == page_js, key+':realm-JS-coherence')
                defects = identity_issues(row['js'], row['http']['headers'], availability.get(op))
                if op == 'negative-language':
                    need(defects == ['languages'] and row['http']['headers']['accept-language'] == 'xx', key+':actual-identity-negative')
                else:
                    need(not defects, key+':HTTP-JS:' + ','.join(defects))
                if op in ('page','cross','cross-redirect'):
                    need(all(wire.get('headers',{}).get(k) is not None for k in HIGH), key+':Accept-CH-delegation')
                if op == 'cross-not-delegated':
                    need(all(wire.get('headers',{}).get(k) is None for k in HIGH), key+':nondelegation-negative')
                if op in ('redirect','cross-redirect'):
                    redirect = [x for x in receipts if x.get('nonce') == row['nonce'] and x.get('path') == ('/redirect' if op == 'redirect' else '/cross-redirect')]
                    need(len(redirect) == 1 and redirect[0]['headers']['user-agent'] == page_js['userAgent'] and redirect[0]['tls'] is True, key+':redirect-hop')
                    if len(redirect) == 1: wire_valid(redirect[0], 'a', key+':redirect-hop')
            need(route_failures == 0, prefix+'explicit-route')
            initial = [x for x in receipts if x['path'] == '/']
            need(len(initial) == 1 and initial[0].get('tls') is True and initial[0]['headers']['user-agent'] == page_js['userAgent'] and all(initial[0]['headers'][k] is None for k in HIGH), prefix+'cold-before-Accept-CH')
            if len(initial) == 1: wire_valid(initial[0], 'a', prefix+'initial-document')
            for resource, role in [('/warm','b'),('/policy-control','a'),('/worker.js','a'),('/owned-sw.js','a')]:
                observed = [x for x in receipts if x['path'] == resource]
                need(bool(observed), prefix+'resource:'+resource)
                for wire in observed: wire_valid(wire, role, prefix+'resource:'+resource)
    except (KeyError, TypeError, ValueError, IndexError, AttributeError):
        issues.append('missing-or-malformed-observation')
    return {'passed':not issues, 'checks':checks, 'issues':issues}


def main():
    observation, release_file, reference_file = map(Path, sys.argv[1:])
    report = json.loads(observation.read_text()); release = json.loads(release_file.read_text()); reference = json.loads(reference_file.read_text())
    result = verify(report, release, reference)
    for i, key in enumerate(SOURCES):
        source = observation.parent/'sources'/f'{i}-{Path(key).name}'
        if (not source.is_file() or source.is_symlink()
                or hashlib.sha256(source.read_bytes()).hexdigest() != report.get('sources',{}).get(key)):
            result['issues'].append('retained-source-binding');result['passed']=False
    for key, file in [('releaseReportSHA256',release_file)]:
        if report.get(key) != hashlib.sha256(file.read_bytes()).hexdigest():
            result['issues'].append('independent-file-binding');result['passed']=False
    if report.get('reference',{}).get('bindingSHA256') != hashlib.sha256(reference_file.read_bytes()).hexdigest():
        result['issues'].append('independent-reference-binding');result['passed']=False
    negatives=[]
    if result['passed']:
        for label, mutate in [
            ('missing-operation',lambda d:d['sessions'][2]['result']['rows'].pop(0)),
            ('missing-SW',lambda d:d['sessions'][2]['result'].__setitem__('unregistered',False)),
            ('wrong-nonce',lambda d:d['sessions'][2]['result']['rows'][0].__setitem__('nonce','stale')),
            ('TLS-missing',lambda d:d['sessions'][2]['receipts'][0].__setitem__('tls',False)),
            ('proxy-custody-missing',lambda d:d['sessions'][2]['result']['rows'][0]['http'].__setitem__('receiptID','missing')),
            ('header-missing',lambda d:d['sessions'][2]['result']['rows'][0]['http']['headers'].pop('sec-ch-ua')),
            ('duplicate-receipt',lambda d:d['sessions'][2]['receipts'].append(copy.deepcopy(d['sessions'][2]['receipts'][0]))),
            ('missing-Direct-negative',lambda d:d['sessions'].pop()),
        ]:
            changed=copy.deepcopy(report);mutate(changed);negatives.append({'name':label,'rejected':not verify(changed,release,reference)['passed']})
    result['negativeControls']=negatives
    result['negativeControlsQualified']=result['passed'] and bool(negatives) and all(x['rejected'] for x in negatives)
    result['observationSHA256']=hashlib.sha256(observation.read_bytes()).hexdigest()
    observation.with_name('verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result));return 0 if result['negativeControlsQualified'] else 1


if __name__ == '__main__':
    sys.exit(main())
