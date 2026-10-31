"""One reviewed, source-derived linker cache; never a blanket cache exclusion."""
import copy
import hashlib
import json
import subprocess
from pathlib import Path
import chromium_15540_release_evidence as base
from chromium_15540_source_snapshot import compact_snapshot

CACHE = 'build/toolchain/__pycache__/whole_archive.cpython-314.pyc'
SOURCE = 'build/toolchain/whole_archive.py'
SOURCE_HASH = 'bf50036f79643f17efd30f79f9b1e479f623f322e7a37f9dccbbea2b69b34a02'
CACHE_HASH = 'e62b2a6bf86894ed996ea25a5d8e89a48618eefcdc05ad221f2a9daf4439e102'
POST_SNAPSHOT_HASH = '81fe001ace5160375ee7446eefdd1ae9cddf9488af0cbdb80bec32b86b3f38d8'


def reviewed_document():
    return {'schemaVersion': 1, 'kind': 'source-derived-build-cache',
                'semanticCorrectionSet': 'canvas-audio-webgl-native-webrtc-v3',
                'cachePath': CACHE, 'cacheSHA256': CACHE_HASH, 'sizeBytes': 2178, 'mode': 420,
                'sourcePath': SOURCE, 'sourceSHA256': SOURCE_HASH,
                'pythonVersion': '3.14', 'freshCompiledCodeMatches': True,
                'sourceTimestampAndLengthMatch': True,
                'prebuildCacheAbsent': True, 'postBuildSnapshotSHA256': POST_SNAPSHOT_HASH,
                'releaseReady': False}


def verify_document(document):
    expected = reviewed_document()
    if document != expected or any(type(document.get(k)) is not type(v) for k, v in expected.items()):
        raise base.M15540EvidenceError('Unknown linker cache derivation evidence')


def normalize(full, document):
    verify_document(document)
    result = copy.deepcopy(full)
    caches = [e for e in result['entries'] if e['path'] == CACHE]
    expected = {'kind': 'file', 'path': CACHE, 'mode': 420, 'sizeBytes': 2178, 'sha256': CACHE_HASH}
    if caches != [expected]:
        raise base.M15540EvidenceError('Generated linker cache differs from reviewed bytecode')
    source = [e for e in result['entries'] if e['path'] == SOURCE]
    if len(source) != 1 or source[0].get('sha256') != SOURCE_HASH:
        raise base.M15540EvidenceError('Linker Python source changed')
    result['entries'] = [e for e in result['entries'] if e['path'] != CACHE]
    result['sourceFileCount'] -= 1
    return result


def verify_live(source, document):
    verify_document(document)
    for name, digest in ((SOURCE, SOURCE_HASH), (CACHE, CACHE_HASH)):
        if base.sha256_file(base.safe_relative_regular(source, name)) != digest:
            raise base.M15540EvidenceError('Linker source/cache live bytes changed')
    # Read code objects, never execute the cache. Compare all recursive code
    # attributes against a fresh compilation by the actual build interpreter.
    program = '''import importlib.util,marshal,struct,sys,types
from pathlib import Path
def need(ok):
 if not ok:raise ValueError('Linker cache derivation mismatch')
need(sys.version_info[:2] == (3,14))
root=Path(sys.argv[1]);source=root/'build/toolchain/whole_archive.py';raw=(root/'build/toolchain/__pycache__/whole_archive.cpython-314.pyc').read_bytes()
need(raw[:4]==importlib.util.MAGIC_NUMBER and len(raw)>16)
code=marshal.loads(raw[16:]);need(isinstance(code,types.CodeType))
need(code.co_filename==str(root/'build/toolchain/apple/../whole_archive.py'))
fresh=compile(source.read_bytes(),code.co_filename,'exec',dont_inherit=True,optimize=0)
def same(a,b):
 fields=('co_argcount','co_posonlyargcount','co_kwonlyargcount','co_nlocals','co_stacksize','co_flags','co_code','co_names','co_varnames','co_filename','co_name','co_qualname','co_firstlineno','co_linetable','co_exceptiontable','co_freevars','co_cellvars')
 need(all(getattr(a,k)==getattr(b,k) for k in fields) and len(a.co_consts)==len(b.co_consts))
 for x,y in zip(a.co_consts,b.co_consts):
  if isinstance(x,types.CodeType):need(isinstance(y,types.CodeType));same(x,y)
  else:need(type(x) is type(y) and x==y)
same(code,fresh)
need(struct.unpack('<I',raw[4:8])[0]==0)
need(struct.unpack('<I',raw[8:12])[0]==int(source.stat().st_mtime))
need(struct.unpack('<I',raw[12:16])[0]==source.stat().st_size)
print('verified-derived-linker-bytecode')
'''
    try:
        result = subprocess.run(['/opt/homebrew/bin/python3.14', '-I', '-B', '-c', program, str(source)],
                                capture_output=True, text=True, timeout=15)
    except (subprocess.TimeoutExpired, UnicodeError) as error:
        raise base.M15540EvidenceError('Linker cache derivation could not be completed') from error
    if result.returncode != 0 or result.stdout.strip() != 'verified-derived-linker-bytecode':
        raise base.M15540EvidenceError('Linker bytecode does not match fresh source compilation')


def snapshot_digest(snapshot):
    return hashlib.sha256((json.dumps(snapshot, sort_keys=True, indent=2) + '\n').encode()).hexdigest()
