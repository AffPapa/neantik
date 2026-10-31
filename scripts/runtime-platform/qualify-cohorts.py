#!/usr/bin/env python3
"""Finite headed tuple projection; reuses unchanged drawing/API qualification.

One owned session per immutable tuple. The four issued Air cohorts are already
included. Private captures retain synthetic values; the public summary contains
only cohort IDs, hashes, verdicts and explicit limits. No ordinary profiles.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location('cohort_platform_binding', HERE / 'qualify-candidate.py')
BASE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(BASE)


def require(condition, reason):
    if not condition: raise ValueError('cohort-' + reason)


def verify(capture, row, seed, binding, launch_hash, fixtures):
    require(BASE.capture_binding_matches(capture, binding), 'candidate-or-cleanup')
    require(BASE.source_binding_matches(capture, fixtures), 'fixture-source')
    binding_hash=hashlib.sha256((json.dumps(binding,sort_keys=True,indent=2)+'\n').encode()).hexdigest()
    require(capture.get('candidateBindingSHA256')==binding_hash
            and capture.get('probeSHA256')==BASE.digest(fixtures/'vector-semantics/cohort-projection-probe.js')
            and capture.get('runnerSHA256')==BASE.digest(fixtures/'vector-semantics/run-headed-m156.mjs'), 'expected-probe-or-binding')
    closure=capture.get('browserClosure',{})
    require(closure.get('gracefulParentExit') is True and type(closure.get('parentExitCode')) is int
            and closure['parentExitCode']==0 and closure.get('parentSignal') is None, 'graceful-parent-exit')
    require(capture['label'] == f'cohort-{seed}' and capture['mode'] == 'neantik-configured'
            and capture['syntheticConfiguration'] == dict(profileSeed=seed, scope='synthetic-direct-manager-policy',
                launchReceiptSHA256=launch_hash), 'launch-contract')
    data = capture['data']
    require(data['kind'] == 'finite-cohort-projection' and data['errors'] == [], 'probe-failed')
    require(data['first'] == data['repeat'], 'repeated-read-drift')
    value = data['first']
    require(type(value['cpu']) is int and value['cpu'] == row['hardwareConcurrency'], 'cpu')
    require(type(value['memory']) in (int,float) and value['memory'] == row['webDeviceMemoryGB'], 'memory')
    require(value['screen'] == row['screen'], 'screen')
    require(value['hints'] == dict(architecture='arm', bitness='64', mobile=False,
        platform='macOS', platformVersion=row['platformVersion']) and value['hints']['mobile'] is False, 'platform-hints')
    require(value['renderer'] == f"ANGLE (Apple, ANGLE Metal Renderer: Apple {row['gpuModel']}, Unspecified Version)", 'gpu')
    return True


def sensitivity(capture, row, seed, binding, launch_hash, fixtures):
    """The actual positive capture must reject deliberate contradictory values."""
    def pair(c,key,value):
        for phase in ('first','repeat'):c['data'][phase][key]=copy.deepcopy(value)
    edits = [('cpu', lambda c: pair(c,'cpu',1)),
        ('memory', lambda c: pair(c,'memory',1)),
        ('screen', lambda c: pair(c,'screen','wrong')),
        ('gpu-family-substring', lambda c: pair(c,'renderer','Apple M1 Pro')),
        ('platform', lambda c: pair(c,'hints',dict(c['data']['first']['hints'],platformVersion='0.0.0'))),
        ('repeat-drift', lambda c: c['data']['repeat'].__setitem__('cpu', 1)),
        ('wrong-seed', lambda c: c['syntheticConfiguration'].__setitem__('profileSeed', seed+1)),
        ('missing-cleanup', lambda c: c.__setitem__('cleanupVerified', False)),
        ('wrong-runtime', lambda c: c.__setitem__('executableSHA256', '0'*64)),
        ('missing-document', lambda c: c.__setitem__('documentEvidence', {})),
        ('missing-source', lambda c: c.__setitem__('fixtureProvenance', {}))]
    for name, mutate in edits:
        broken = copy.deepcopy(capture); mutate(broken)
        try: verify(broken, row, seed, binding, launch_hash, fixtures)
        except (ValueError, KeyError, TypeError): continue
        raise ValueError('cohort-insensitive-control-' + name)
    return [name for name,_ in edits]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--launch-receipts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(all(p.is_absolute() for p in (args.app,args.manifest,args.launch_receipts,args.output)), 'absolute-inputs')
    runtime, binding = BASE.binding_for(args.app, args.manifest)
    rows = json.loads((ROOT/'runtime/apple-device-tuples.json').read_text())['tuples']
    require(len(rows) == 11, 'review-required-on-catalog-change')
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    info=args.output.lstat()
    require(not args.output.is_symlink() and info.st_uid==os.getuid() and info.st_mode & 0o077 == 0, 'private-output')
    fixtures = args.output/'fixtures'
    source = HERE/'fixtures'
    if not fixtures.exists(): shutil.copytree(source, fixtures)
    for file in source.rglob('*'):
        if file.is_file(): require(BASE.digest(file)==BASE.digest(fixtures/file.relative_to(source)), 'changed-input-use-new-output')
    binding_path=args.output/'binding.json';BASE.write_once(binding_path,binding)
    BASE.write_once(args.output/'tuple-contract.json',dict(tuples=rows,sourceSHA256=BASE.digest(ROOT/'runtime/apple-device-tuples.json')))
    summaries=[]
    for index,row in enumerate(rows):
        seed=11+index;label=f'cohort-{seed}'
        original=args.launch_receipts/f'seed-{seed}.json'
        receipt=json.loads(original.read_text())
        require(receipt['managerPolicySourceSHA256']==BASE.digest(ROOT/'Sources/NeAntik/BrowserProcessManager.swift'), 'manager-policy-drift')
        require(receipt['environment']=={'NEANTIK_PROFILE_SEED':str(seed)}, 'receipt-seed')
        launch=args.output/f'seed-{seed}-manager.json';BASE.write_once(launch,receipt)
        options=args.output/f'seed-{seed}-options.json';BASE.write_once(options,dict(seed=seed))
        capture_path=fixtures/f'vector-semantics/{label}-observations.json'
        if not capture_path.exists():
            readiness=subprocess.run(['python3','-B',str(ROOT/'scripts/native-qa-readiness.py'),'--check'],capture_output=True,text=True)
            BASE.write_once(args.output/f'{label}-readiness.json',json.loads(readiness.stdout))
            require(readiness.returncode==0 and json.loads(readiness.stdout)['eligibleForAttempt'] is True, 'native-admission-deferred')
            env=dict(os.environ,NEANTIK_PLATFORM_BINDING=str(binding_path),NEANTIK_PLATFORM_LAUNCH_RECEIPT=str(launch))
            with (args.output/f'{label}-private.log').open('x') as log:
                result=subprocess.run(['node',str(fixtures/'vector-semantics/run-headed-m156.mjs'),str(runtime),label,
                    'neantik-configured',binding['runtimeExecutableSHA256'],str(options),'cohort-projection-probe.js'],
                    env=env,stdout=log,stderr=subprocess.STDOUT,timeout=180)
            require(result.returncode==0, 'capture-failed-see-private-log')
        capture=json.loads(capture_path.read_text())
        verify(capture,row,seed,binding,BASE.digest(launch),fixtures)
        controls=sensitivity(capture,row,seed,binding,BASE.digest(launch),fixtures)
        summary=dict(tupleID=row['id'],result='scoped-projection-pass',captureSHA256=BASE.digest(capture_path),negativeControls=controls)
        BASE.write_once(args.output/f'{label}-verdict.json',summary)
        summaries.append(summary)
        print(json.dumps(dict(tupleID=row['id'],result='scoped-projection-pass')),flush=True)
    report=dict(schemaVersion=1,result='finite-cohort-projection-pass',headed=True,tuples=summaries,
        binding=binding,managerPolicySourceSHA256=BASE.digest(ROOT/'Sources/NeAntik/BrowserProcessManager.swift'),
        runnerSHA256=BASE.digest(Path(__file__)),releaseGate=False,
        scope='11 synthetic tuple projections: CPU, web memory, screen/DPR, platform hints, canonical GPU and repeat reads',
        open=['full API operations reused only from matching archived receipts','font policy','voices locales/events',
              'codec/PDF compatibility','HTTPS identity','other OS/hardware'])
    BASE.write_once(args.output/'summary.json',report)


if __name__ == '__main__': main()
