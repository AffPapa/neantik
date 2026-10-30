import copy
import hashlib
import io
import os
import tarfile
import tempfile
import unittest
from unittest import mock
from pathlib import Path
import chromium_15612_tool_packages as module
from chromium_15612_generated_cache import M156CacheError

def deps_fixture():
    deps={}
    for kind,key in module.DEPS_KEYS.items():
        dep=deps.setdefault(key,{'dep_type':'gcs','bucket':'chromium-browser-clang',
                                 'condition':'not '+('rust' if kind=='rust' else 'llvm')+'_force_head_revision','objects':[]})
        p=module.TOOL_PACKAGES[kind]
        dep['objects'].append({'object_name':p['url'].split('/chromium-browser-clang/',1)[1],
                               'sha256sum':p['archiveSHA256'],'size_bytes':p['size'],'generation':module.GENERATION[kind],
                               'condition':'host_os == "mac" and host_cpu == "arm64"'})
    return deps

def fixture(root):
    entries=[{'path':'bin','kind':'directory','size':0,'mode':'0o755','link':None},
             {'path':'bin/tool','kind':'file','size':7,'mode':'0o755','link':None},
             {'path':'bin/header','kind':'file','size':6,'mode':'0o644','link':None},
             {'path':'bin/alias','kind':'symlink','size':0,'mode':'0o755','link':'tool'}]
    contents={'bin/tool':b'fixture','bin/header':b'header'}
    archive=root/'owned.tar.xz'
    with tarfile.open(archive,'w:xz') as t:
        for e in entries:
            m=tarfile.TarInfo(e['path']);m.mode=int(e['mode'],8);m.size=e['size'];m.mtime=1
            if e['kind']=='directory':m.type=tarfile.DIRTYPE
            elif e['kind']=='symlink':m.type=tarfile.SYMTYPE;m.linkname=e['link']
            t.addfile(m,io.BytesIO(contents[e['path']]) if e['kind']=='file' else None)
    raw=archive.read_bytes();expected={'url':'https://example.invalid/owned.tar.xz','archiveSHA256':hashlib.sha256(raw).hexdigest(),
                                      'size':len(raw),'files':2}
    inspection={'url':expected['url'],'sha256':expected['archiveSHA256'],'size':len(raw),'members':entries}
    payload={name:hashlib.sha256(b).hexdigest() for name,b in contents.items()}
    installed=root/'installed';installed.mkdir();(installed/'bin').mkdir(mode=0o755)
    for e in entries:
        if e['kind']=='file':
            p=installed/e['path'];p.write_bytes(contents[e['path']]);p.chmod(int(e['mode'],8))
        elif e['kind']=='symlink':(installed/e['path']).symlink_to(e['link'])
    return inspection,payload,expected,installed

class OfficialDEPSPackagesTests(unittest.TestCase):
    def test_selected_exact_three_objects_without_execution(self):
        result=module.deps_packages(('deps = '+repr(deps_fixture())).encode())
        self.assertEqual(set(result),{'clang','rust','llvmobjdump'})
        self.assertEqual(result['llvmobjdump']['DEPSGeneration'],1790402697359142)
        self.assertFalse(result['clang']['serverGenerationObserved'])

    def test_comments_wrong_sections_cpu_generation_boolean_or_duplicate_object_fail(self):
        with self.assertRaises(M156CacheError):module.deps_packages(('# deps = '+repr(deps_fixture())+'\ndeps = {}').encode())
        for field,value in [('bucket','unrelated'),('condition','not unrelated'),('dep_type','git')]:
            d=deps_fixture();d[module.DEPS_KEYS['clang']][field]=value
            with self.assertRaises(M156CacheError):module.deps_packages(('deps = '+repr(d)).encode())
        for field,value in [('condition','host_os == "mac" and host_cpu == "x64"'),('generation',True),
                            ('generation',1790402697155563),('size_bytes',True),('sha256sum','b'*64)]:
            d=deps_fixture();d[module.DEPS_KEYS['clang']]['objects'][0][field]=value
            with self.assertRaises(M156CacheError):module.deps_packages(('deps = '+repr(d)).encode())
        d=deps_fixture();d[module.DEPS_KEYS['clang']]['objects'].append(copy.deepcopy(d[module.DEPS_KEYS['clang']]['objects'][0]))
        with self.assertRaises(M156CacheError):module.deps_packages(('deps = '+repr(d)).encode())

    def test_duplicate_dependency_or_executable_expression_fail(self):
        d=deps_fixture();k=module.DEPS_KEYS['clang'];raw='deps = {'+repr(k)+':'+repr(d[k])+','+repr(k)+':'+repr(d[k])+','+repr(module.DEPS_KEYS['rust'])+':'+repr(d[module.DEPS_KEYS['rust']])+'}'
        with self.assertRaises(M156CacheError):module.deps_packages(raw.encode())
        raw='deps = {'+repr(k)+':make_toolchain(),'+repr(module.DEPS_KEYS['rust'])+':'+repr(d[module.DEPS_KEYS['rust']])+'}'
        with self.assertRaisesRegex(M156CacheError,'Executable'):module.deps_packages(raw.encode())

    def test_unpacking_or_dynamic_key_cannot_override_a_valid_dependency(self):
        d=deps_fixture();k=module.DEPS_KEYS['clang'];original=repr(d)
        for addition in [', **{'+repr(k)+': {}}',', ('+repr(k)+' + ""): {}']:
            raw='deps = '+original[:-1]+addition+'}'
            with self.assertRaisesRegex(M156CacheError,'Dynamic DEPS key'):module.deps_packages(raw.encode())

class ToolPayloadTests(unittest.TestCase):
    def test_actual_fixture_archive_and_installed_files_modes_links(self):
        with tempfile.TemporaryDirectory(prefix='neantik-tool-payload-') as temp:
            root=Path(temp);inspection,payload,expected,installed=fixture(root)
            members=module.metadata(inspection,payload,expected)
            module.verify_archive(root,'owned.tar.xz',inspection,payload,expected)
            derived,p=module.observe_verified_archive(root,'owned.tar.xz',expected)
            self.assertEqual((derived,p),(inspection,payload))
            module.verify_installed(installed,members,payload)

    def test_extra_missing_changed_size_mode_symlink_or_hardlink_refused(self):
        for fault in ['extra','missing','bytes','mode','symlink','hardlink']:
            with self.subTest(fault=fault),tempfile.TemporaryDirectory(prefix='neantik-tool-fault-') as temp:
                inspection,payload,expected,installed=fixture(Path(temp));path=installed/'bin/header'
                if fault=='extra':(installed/'bin/extra').write_bytes(b'x')
                elif fault=='missing':path.unlink()
                elif fault=='bytes':path.write_bytes(b'broken')
                elif fault=='mode':path.chmod(0o666)
                elif fault=='symlink':path.unlink();path.symlink_to('tool')
                else:os.link(path,installed.parent/'hardlink-owned')
                with self.assertRaises(M156CacheError):module.verify_installed(installed,module.metadata(inspection,payload,expected),payload)

    def test_wrong_archived_payload_digest_inspection_or_archive_bytes_fail(self):
        with tempfile.TemporaryDirectory(prefix='neantik-tool-archive-fault-') as temp:
            root=Path(temp);inspection,payload,expected,_=fixture(root)
            bad=dict(payload);bad['bin/header']='b'*64
            with self.assertRaisesRegex(M156CacheError,'payload digest'):module.verify_archive(root,'owned.tar.xz',inspection,bad,expected)
            bad=copy.deepcopy(inspection);bad['members'][1]['mode']='0o644'
            with self.assertRaisesRegex(M156CacheError,'member metadata'):module.verify_archive(root,'owned.tar.xz',bad,payload,expected)
            raw=(root/'owned.tar.xz').read_bytes();(root/'owned.tar.xz').write_bytes(raw+b'x')
            with self.assertRaises(M156CacheError):module.verify_archive(root,'owned.tar.xz',inspection,payload,expected)

    def test_traversal_chained_undeclared_dangling_duplicate_and_type_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            inspection,payload,expected,_=fixture(Path(temp))
            for target in ['../../outside','/outside','alias','not-declared']:
                d=copy.deepcopy(inspection);d['members'][-1]['link']=target
                with self.assertRaises(M156CacheError):module.metadata(d,payload,expected)
            for changes in [{'path':'../outside'},{'kind':'hardlink'},{'size':True},{'mode':'0o4755'}]:
                d=copy.deepcopy(inspection);d['members'][1].update(changes)
                with self.assertRaises(M156CacheError):module.metadata(d,payload,expected)
            d=copy.deepcopy(inspection);d['members'].append(d['members'][0])
            with self.assertRaises(M156CacheError):module.metadata(d,payload,expected)

    def test_only_declared_official_dangling_compatibility_link_allowed(self):
        path=next(iter(module.DANGLING_COMPATIBILITY_LINKS));parts=path.split('/');members=[]
        for end in range(1,len(parts)):members.append({'path':'/'.join(parts[:end]),'kind':'directory','size':0,'mode':'0o755','link':None})
        members.append({'path':path,'kind':'symlink','size':0,'mode':'0o755','link':module.DANGLING_COMPATIBILITY_LINKS[path]})
        expected={'url':'https://example.invalid/owned','archiveSHA256':'a'*64,'size':1,'files':0}
        inspection={'url':expected['url'],'sha256':'a'*64,'size':1,'members':members}
        module.metadata(inspection,{},expected)
        inspection['members'][-1]['link']='unknown'
        with self.assertRaises(M156CacheError):module.metadata(inspection,{},expected)

    def test_growing_or_replaced_file_rejected(self):
        with tempfile.TemporaryDirectory(prefix='neantik-tool-read-fault-') as temp:
            root=Path(temp);path=root/'owned';path.write_bytes(b'hello')
            with self.assertRaises(M156CacheError):
                with module.held_file(root,'owned',5) as (stream,before):
                    path.write_bytes(b'hello!');module.stream_hash(stream,before.st_size)
            path.write_bytes(b'hello')
            with self.assertRaisesRegex(M156CacheError,'changed'):
                with module.held_file(root,'owned',5) as (stream,before):
                    module.stream_hash(stream,before.st_size);path.rename(root/'preserved');path.write_bytes(b'hello')

    def test_trusted_source_prefix_rejects_intermediate_symlink_and_dotdot(self):
        with tempfile.TemporaryDirectory(prefix='neantik-tool-ancestor-fault-') as temp:
            root=Path(temp);inspection,payload,expected,installed=fixture(root)
            source=root/'source';source.mkdir();(source/'third_party').mkdir()
            real=source/'third_party/llvm-build';real.mkdir();installed.rename(real/'Release+Asserts')
            members=module.metadata(inspection,payload,expected)
            module.verify_installed(source,members,payload,'third_party/llvm-build/Release+Asserts')
            real.rename(root/'preserved');real.symlink_to(root/'preserved',target_is_directory=True)
            with self.assertRaises(OSError):module.verify_installed(source,members,payload,'third_party/llvm-build/Release+Asserts')
            with self.assertRaises(M156CacheError):module.verify_installed(source,members,payload,'third_party/../preserved/Release+Asserts')

    def test_replacement_of_intermediate_directory_after_open_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='neantik-tool-ancestor-race-') as temp:
            root=Path(temp);(root/'third_party').mkdir();(root/'third_party/owned').mkdir()
            (root/'third_party/owned/file').write_bytes(b'hello')
            with self.assertRaisesRegex(M156CacheError,'Intermediate source directory replaced'):
                with module.held_file(root,'third_party/owned/file',5) as (stream,before):
                    module.stream_hash(stream,before.st_size)
                    (root/'third_party').rename(root/'preserved');(root/'third_party').mkdir()

if __name__=='__main__':unittest.main()
