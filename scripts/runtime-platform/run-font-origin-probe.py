#!/usr/bin/env python3
"""One guarded CoreText primitive run; not a Chromium build or qualification."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ('runtime/font-policy-v1/system_font_source.h',
           'runtime/font-policy-v1/system_font_source.cc',
           'scripts/runtime-platform/probe-font-origin.mm',
           'scripts/runtime-platform/make-font-policy-canary.py',
           'scripts/runtime-platform/run-font-origin-probe.py',
           'scripts/runtime-platform/requirements-font-qa.txt',
           'scripts/native-qa-readiness.py')


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def run(output, qa_python):
    assert output.is_absolute() and qa_python.is_absolute()
    info = output.lstat()
    assert output.is_dir() and not output.is_symlink() and info.st_uid == os.getuid() and not info.st_mode & 0o077
    assert not any(output.iterdir()), 'Fresh empty owned output required'
    env = {k:v for k,v in os.environ.items() if k in {'HOME','PATH','TMPDIR','LANG','LC_ALL','USER','LOGNAME','DEVELOPER_DIR'}}
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    ready = subprocess.run(['python3','-B',str(ROOT/'scripts/native-qa-readiness.py'),'--check'],capture_output=True,env=env)
    (output/'readiness.json').write_bytes(ready.stdout)
    if ready.returncode:
        print(json.dumps({'status':'resource-blocked-before-native','exitCode':ready.returncode}));return ready.returncode
    processes = subprocess.check_output(['/bin/ps','-axo','comm='],text=True)
    assert not any(Path(row.strip()).name in {'ninja','autoninja','siso','clang','clang++','swiftc','swift-frontend'} for row in processes.splitlines()), 'Another native build is active'
    package = subprocess.run([str(qa_python),'-B','-c','from importlib.metadata import version;print(version("fonttools"))'],capture_output=True,text=True,check=True,env=env)
    assert package.stdout.strip() == '4.67.0', 'Use the pinned private QA dependency'
    canary = output/'canary';canary.mkdir(mode=0o700)
    generated = subprocess.run([str(qa_python),'-B',str(ROOT/SOURCES[3]),str(canary)],capture_output=True,env=env)
    (output/'canary-generator.log').write_bytes(generated.stdout+generated.stderr)
    assert generated.returncode == 0, 'Own canary generation failed'
    source = {f:digest(ROOT/f) for f in SOURCES}
    for i,f in enumerate(SOURCES):(output/f'{i}-{Path(f).name}').write_bytes((ROOT/f).read_bytes())
    compiler = subprocess.check_output(['/usr/bin/xcrun','--find','clang++'],text=True,env=env).strip()
    sdk = subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],text=True,env=env).strip()
    cache = output/'compiler-cache';cache.mkdir(mode=0o700)
    binary = output/'font-origin-probe'
    command = [compiler,'-x','objective-c++','-std=c++20','-fobjc-arc','-isysroot',sdk,'-target','arm64-apple-macos14',
               '-fmodules-cache-path='+str(cache),str(ROOT/SOURCES[1]),str(ROOT/SOURCES[2]),
               '-framework','CoreText','-framework','CoreFoundation','-framework','CoreGraphics','-framework','Foundation','-o',str(binary)]
    receipt = {'schemaVersion':1,'status':'development-native-incomplete','sourceSHA256':source,'compiler':compiler,'SDK':sdk,
               'command':command,'actualBrowser':False,'productionFilesChanged':False,'startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    try:
        with (output/'compile.log').open('w') as log:
            compiled=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=180)
        if compiled.returncode:
            receipt.update(status='compile-failed',exitCode=compiled.returncode)
        else:
            with (output/'observations.json').open('w') as result,(output/'native-errors-private.log').open('w') as error:
                native=subprocess.run([str(binary),str(canary)],stdout=result,stderr=error,env=env,timeout=30)
            receipt.update(status='native-primitive-complete' if native.returncode==0 else 'native-primitive-failed',
                           exitCode=native.returncode,binarySHA256=digest(binary),observationsSHA256=digest(output/'observations.json'))
    except subprocess.TimeoutExpired:
        # subprocess.run kills and waits for the owned child before raising.
        # A crashed/killed process loses its process-scoped registrations.
        receipt.update(status='owned-process-timeout',exitCode=124)
    if any(digest(ROOT/file)!=pin for file,pin in source.items()):
        receipt.update(status='source-changed-during-run',exitCode=1)
    receipt['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({key:receipt[key] for key in ('status','exitCode','actualBrowser')}))
    return receipt['exitCode'] if receipt['exitCode']>=0 else 1


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('output',type=Path);parser.add_argument('qa_python',type=Path);args=parser.parse_args()
    sys.exit(run(args.output,args.qa_python))
