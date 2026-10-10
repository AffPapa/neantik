import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from chromium_15612_generated_cache import (
    COMMIT, TREE, VERSION, M156CacheError, compare_inventories, inventory,
    read_source_file, verify_cache, MarshalPreflight, CACHE_CHECK_PROGRAM,
)

H = 'a' * 64
PYTHON = Path('/opt/homebrew/bin/python3.14')

def file(name, digest=H, size=1):
    return {'kind':'file','path':name,'mode':0o644,'sizeBytes':size,'sha256':digest}

def snapshot(entries):
    return {'schemaVersion':1,'recordType':'chromium-source-snapshot',
            'targetChromiumVersion':VERSION,'officialChromiumBase':{'commit':COMMIT,'tree':TREE},
            'argsGN':{'relativePath':'out/NeAntikM156Qualified20261009/args.gn',
                      'sha256':'b32623308042c6b3b86f14ce9635ccc9abdc290148ce596c1e4f4a43ffde9a01'},
            'entries':sorted(entries,key=lambda x:x['path']),'deletedPaths':[],
            'sourceFileCount':len(entries),'deletedPathCount':0,'releaseReady':False}

class M156GeneratedCacheTests(unittest.TestCase):
    def test_unchanged_and_added_or_regenerated_cache(self):
        source=file('tools/owned.py')
        cache=file('tools/__pycache__/owned.cpython-314.pyc')
        a,b=snapshot([source]),snapshot([source,cache])
        self.assertEqual(compare_inventories(a,a),[])
        self.assertEqual(compare_inventories(a,b)[0]['source'],'tools/owned.py')
        c=copy.deepcopy(b);c['entries'][0]['sha256']='b'*64
        self.assertEqual(compare_inventories(b,c)[0]['cacheSHA256'],'b'*64)

    def test_noncache_source_deltas_rejected(self):
        a=snapshot([file('tools/owned.py')])
        bad=[snapshot([file('tools/owned.py','b'*64)]),
             snapshot([file('tools/owned.py'),file('tools/unreviewed.py')]),
             snapshot([file('tools/__pycache__/absent.cpython-314.pyc')]),
             snapshot([file('tools/owned.py'),file('tools/__pycache__/owned.cpython-313.pyc')])]
        for b in bad:
            with self.subTest(b=b),self.assertRaises(M156CacheError):compare_inventories(a,b)

    def test_cache_deletion_permission_special_type_and_unknown_fields_rejected(self):
        source=file('tools/owned.py');cache=file('tools/__pycache__/owned.cpython-314.pyc');a=snapshot([source,cache])
        with self.assertRaises(M156CacheError):compare_inventories(a,snapshot([source]))
        for key,value in [('mode',0o666),('kind','fifo'),('sizeBytes',4*1024*1024+1),('unreviewed',True)]:
            b=snapshot([source,{**cache,key:value}])
            with self.subTest(key=key),self.assertRaises(M156CacheError):compare_inventories(snapshot([source]),b)

    def test_changed_args_deleted_paths_and_identity_rejected(self):
        a=snapshot([file('tools/owned.py')])
        for patch in [{'schemaVersion':True},{'targetChromiumVersion':'155.0.8059.40'},
                      {'releaseReady':True},{'sourceFileCount':True},{'deletedPaths':['old.py'],'deletedPathCount':1},
                      {'argsGN':{**a['argsGN'],'sha256':'b'*64}}]:
            b={**a,**patch}
            with self.subTest(patch=patch),self.assertRaises(M156CacheError):compare_inventories(a,b)

    def test_duplicate_traversal_unsorted_and_present_deleted_rejected(self):
        bad=[snapshot([file('a.py'),file('a.py')]),snapshot([file('../owned.py')]),snapshot([file('/owned.py')]),
             snapshot([file('a\\owned.py')])]
        wrong=snapshot([file('a.py'),file('b.py')]);wrong['entries'].reverse();bad.append(wrong)
        wrong=snapshot([file('a.py')]);wrong.update(deletedPaths=['a.py'],deletedPathCount=1);bad.append(wrong)
        for d in bad:
            with self.subTest(d=d),self.assertRaises(M156CacheError):inventory(d)

    def test_descriptor_reader_rejects_links_fifo_ancestors_and_bounds(self):
        with tempfile.TemporaryDirectory(prefix='neantik-cache-fd-') as temp:
            root=Path(temp);(root/'owned').write_bytes(b'own');(root/'dir').mkdir();(root/'dir'/'data').write_bytes(b'data')
            self.assertEqual(read_source_file(root,'dir/data',4),b'data')
            (root/'symlink').symlink_to(root/'owned');os.link(root/'owned',root/'hardlink');os.mkfifo(root/'fifo');(root/'dirlink').symlink_to(root/'dir')
            for name in ['symlink','hardlink','fifo','dirlink/data','../owned']:
                with self.subTest(name=name),self.assertRaises((M156CacheError,OSError)):read_source_file(root,name,16)
            with self.assertRaises(M156CacheError):read_source_file(root,'dir/data',3)

    def test_preflight_rejects_huge_allocations_without_decoding(self):
        import struct
        # Do not send these hostile allocation counts to marshal at all.
        for body in (b'('+struct.pack('<i',2**31-1), b's'+struct.pack('<i',2**31-1),
                     b'>'+struct.pack('<i',2**31-1), b'l'+struct.pack('<i',-2**31),
                     b'c'+struct.pack('<iiiii',0,0,0,2**31-1,0),
                     b'['+struct.pack('<i',1)+b'N', b'{0', b'r'+struct.pack('<i',0),
                     bytes([ord(')')|128,1])+b'r'+struct.pack('<i',0)):
            with self.subTest(body=body),self.assertRaises(M156CacheError):
                MarshalPreflight(body).validate()
        with self.assertRaises(M156CacheError):
            MarshalPreflight(b')\x01'*66+b'N').validate()
        with self.assertRaises(M156CacheError):
            MarshalPreflight(b')\xff' + b'N'*255).validate()  # non-code root

    def test_preflight_charges_referenced_bytecode_for_each_code_object(self):
        import struct
        integer=lambda n:struct.pack('<i',n)
        string=lambda data:b's'+integer(len(data))+data
        text=lambda data:b'z'+bytes([len(data)])+data
        empty=b')\x00'
        header=b'c'+integer(0)*3+integer(1)+integer(0)
        def code(bytecode,consts):
            return (header+bytecode+consts+empty+empty+string(b'')+
                    text(b'/fixture.py')+text(b'owned')+text(b'owned')+
                    integer(1)+string(b'')+string(b''))
        def body(byte_count,children):
            # Ref0 is a single shared code bytes object, not an expanded
            # Python allocation. Hostile test goes to preflight only.
            shared=bytes([ord('s')|128])+integer(byte_count)+b'\x00'*byte_count
            child=code(b'r'+integer(0),empty)
            return code(shared,b'('+integer(children)+child*children)
        MarshalPreflight(body(8,2)).validate()
        with self.assertRaises(M156CacheError):
            MarshalPreflight(body(512*1024,200)).validate()

    @unittest.skipUnless(PYTHON.exists(),'Exact installed CPython3.14 producer unavailable')
    def test_nan_frozenset_multiplicity_and_signed_zero(self):
        start=CACHE_CHECK_PROGRAM.index('operations=0')
        end=CACHE_CHECK_PROGRAM.index('need(code_value(code,0)')
        definitions=CACHE_CHECK_PROGRAM[start:end]
        control=r"""
import struct,types
need=lambda value: None if value else (_ for _ in ()).throw(AssertionError('control failed'))
"""+definitions+r"""
def nan(bits):return struct.unpack('>d',struct.pack('>Q',bits))[0]
a=0x7ff8000000000001;b=0x7ff8000000000002
left=frozenset((nan(a),nan(a),nan(b)))
right=frozenset((nan(a),nan(b),nan(b)))
assert len(left)==len(right)==3
assert constant(left)!=constant(right)
assert constant(frozenset((-0.0,)))!=constant(frozenset((0.0,)))
assert constant((-0.0,-0j))!=constant((0.0,0j))
"""
        result=subprocess.run([str(PYTHON),'-I','-S','-c',control],capture_output=True,timeout=15)
        self.assertEqual(result.returncode,0)

    @unittest.skipUnless(PYTHON.exists(),'Exact installed CPython3.14 producer unavailable')
    def test_actual_native_filename_spelling_and_bitwise_constants(self):
        with tempfile.TemporaryDirectory(prefix='neantik-cache-native-spelling-') as temp:
            root=Path(temp);directory=root/'build'/'toolchain';(directory/'apple').mkdir(parents=True)
            source=directory/'whole_archive.py'
            source.write_text('value=-0.0\nnested=(-0.0, -0j)\ndef nested_code():\n    return -0.0\n')
            cache=directory/'__pycache__'/'whole_archive.cpython-314.pyc'
            producer=r"""
import marshal,py_compile,struct,sys,types
source,cache,filename,mode=sys.argv[1:]
py_compile.compile(source,cfile=cache,dfile=filename,doraise=True)
if mode in ('flip','complex','nested-code'):
 raw=open(cache,'rb').read();code=marshal.loads(raw[16:])
 def change(x):
  if type(x) is float and x==0 and mode=='flip':return 0.0
  if type(x) is complex and mode=='complex':return complex(abs(x.real),abs(x.imag))
  if type(x) is tuple:return tuple(change(y) for y in x)
  if type(x) is types.CodeType:
   values=tuple(0.0 if mode=='nested-code' and x.co_name=='nested_code' and type(y) is float else change(y) for y in x.co_consts)
   return x.replace(co_consts=values)
  return x
 with open(cache,'wb') as out:out.write(raw[:16]+marshal.dumps(change(code)))
"""
            h=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
            interpreter_hash=h(PYTHON.resolve())
            def produce(filename,mode='normal'):
                result=subprocess.run([str(PYTHON),'-I','-S','-c',producer,str(source),str(cache),filename,mode],capture_output=True)
                self.assertEqual(result.returncode,0)
                return {'cache':str(cache.relative_to(root)),'source':str(source.relative_to(root)),
                        'cacheSHA256':h(cache),'sourceSHA256':h(source),'cacheBytes':cache.stat().st_size}
            # Actual linker_driver.py uses this spelling through sys.path.
            native=str(directory/'apple'/'..'/'whole_archive.py')
            verify_cache(root,produce(native),PYTHON,python_sha256=interpreter_hash)
            verify_cache(root,produce(str(source)),PYTHON,python_sha256=interpreter_hash)
            for wrong in [str(directory/'other.py'),'/outside/whole_archive.py','whole_archive.py']:
                with self.subTest(filename=wrong),self.assertRaises(M156CacheError):
                    verify_cache(root,produce(wrong),PYTHON,python_sha256=interpreter_hash)
            for mode in ('flip','complex','nested-code'):
                with self.subTest(mode=mode),self.assertRaises(M156CacheError):
                    verify_cache(root,produce(native,mode),PYTHON,python_sha256=interpreter_hash)

    @unittest.skipUnless(PYTHON.exists(),'Exact installed CPython3.14 producer unavailable')
    def test_real_cache_derivation_and_tamper_controls_without_source_execution(self):
        # Side effects in the source would create this sentinel if the
        # verifier executed/imported it. Only py_compile/compile are allowed.
        with tempfile.TemporaryDirectory(prefix='neantik-cache-derivation-') as temp:
            root=Path(temp);(root/'tools').mkdir();source=root/'tools'/'owned.py';sentinel=root/'must-not-exist'
            source.write_text('from pathlib import Path\nPath('+repr(str(sentinel))+').write_text("executed")\ndef owned(x):\n    return x + 17\n')
            result=subprocess.run([str(PYTHON),'-I','-S','-c','import py_compile,sys;py_compile.compile(sys.argv[1],doraise=True)',str(source)],capture_output=True)
            self.assertEqual(result.returncode,0)
            cache=root/'tools'/'__pycache__'/'owned.cpython-314.pyc';original=cache.read_bytes()
            h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
            record={'cache':str(cache.relative_to(root)),'source':str(source.relative_to(root)),
                    'cacheSHA256':h(cache),'sourceSHA256':h(source),'cacheBytes':cache.stat().st_size}
            interpreter_hash=h(PYTHON.resolve())
            verify_cache(root,record,PYTHON,python_sha256=interpreter_hash)
            self.assertFalse(sentinel.exists())
            # Even a freshly rebound hash must not bless extra marshal bytes.
            cache.write_bytes(original+b'append')
            wrong={**record,'cacheSHA256':h(cache),'cacheBytes':cache.stat().st_size}
            with self.assertRaises(M156CacheError):verify_cache(root,wrong,PYTHON,python_sha256=interpreter_hash)
            cache.write_bytes(bytes(16)+original[16:])
            wrong={**record,'cacheSHA256':h(cache)}
            with self.assertRaises(M156CacheError):verify_cache(root,wrong,PYTHON,python_sha256=interpreter_hash)
            cache.write_bytes(original)
            with self.assertRaises(M156CacheError):verify_cache(root,record,PYTHON,python_sha256='b'*64)
            # Altered source bytes must fail even though the code is not run.
            source.write_text('raise SystemExit("must not execute")\n')
            with self.assertRaises(M156CacheError):verify_cache(root,record,PYTHON,python_sha256=interpreter_hash)
            self.assertFalse(sentinel.exists())

if __name__=='__main__':unittest.main()
