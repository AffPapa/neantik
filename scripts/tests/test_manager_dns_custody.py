"""Custody format/file controls, separate from live GUI/kernel qualification."""
import ctypes
import importlib.util
import os
from pathlib import Path
import tempfile
import struct
import unittest

PATH=Path(__file__).resolve().parents[1]/'runtime-network/collect-manager-dns.py'
SPEC=importlib.util.spec_from_file_location('manager_dns_custody_test',PATH)
MOD=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MOD)


class ManagerDNSCustodyTests(unittest.TestCase):
    def test_kernel_argv_preserves_spaces_and_rejects_suffix_and_duplicate_flags(self):
        args=['/owned/NeAntik Browser','--user-data-dir=/owned/data','--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1']
        raw=struct.pack('=i',len(args))+b'/owned/NeAntik Browser\0\0'+b'\0'.join(a.encode() for a in args)+b'\0ENV=not-an-argument\0'
        self.assertEqual(MOD.parse_argv(raw),args)
        MOD.flag(args,'--user-data-dir','/owned/data')
        for bad in [args+['--user-data-dir=/other'],['--user-data-dir=/owned/data-other'],['--user-data-dir=/owned/data','--user-data-dir=/owned/data']]:
            with self.assertRaises(ValueError):MOD.flag(bad,'--user-data-dir','/owned/data')
        for bad in [args+['-user-data-dir=/other'],['--',*args],['--user-data-dir=/owned/data','--','-user-data-dir=/other']]:
            with self.assertRaises(ValueError):MOD.flag(bad,'--user-data-dir','/owned/data')
        for name,value in [('--proxy-server','socks5://127.0.0.1:123'),('--proxy-bypass-list','<-loopback>'),('--host-resolver-rules','MAP * ~NOTFOUND, EXCLUDE 127.0.0.1')]:
            for suffix in ['0',';*',', EXCLUDE *']:
                with self.subTest(name=name,suffix=suffix),self.assertRaises(ValueError):MOD.flag([name+'='+value+suffix],name,value)
            with self.assertRaises(ValueError):MOD.flag([name+'='+value,'-'+name.lstrip('-')+'=other'],name,value)
        for malformed in [b'',struct.pack('=i',0)+b'abc\0',raw[:raw.index(b'ENV')-2]]:
            with self.assertRaises(ValueError):MOD.parse_argv(malformed)

    def test_socket_tuple_requires_unique_exact_client_direction_and_pid(self):
        edge='127.0.0.1:4000->127.0.0.1:5000'
        self.assertEqual(MOD.socket_owner('p123\nn'+edge+'\np124\nn127.0.0.1:5000->127.0.0.1:4000\n',edge),123)
        for output in ['', 'p123\nn'+edge+'0\n', 'p123\nn'+edge+'\np124\nn'+edge+'\n', 'n'+edge+'\n']:
            with self.assertRaises(ValueError):MOD.socket_owner(output,edge)

    def test_kernel_abi_and_launch_transition_cover_all_other_metadata(self):
        self.assertEqual(ctypes.sizeof(MOD.BSDInfo),136)
        profile=dict(id='owned',revision=0,updatedAt='before',lastLaunchedAt=None,identity=dict(seed='same'),startURL='one',proxy=None)
        original=MOD.metadata_identity(profile)
        profile.update(revision=1,updatedAt='after',lastLaunchedAt='after')
        self.assertEqual(MOD.metadata_identity(profile),original)
        for field in ('identity','startURL','proxy','futureNewField'):
            changed={**profile,field:'different'}
            self.assertNotEqual(MOD.metadata_identity(changed),original)

    def test_configuration_digest_includes_profile_revision_and_endpoint_not_password(self):
        profile=dict(id='ABC',revision=7,proxy=dict(kind='http',host='127.0.0.1',port=1234,username='owned-fixture-user'))
        self.assertEqual(MOD.configuration_digest(profile),MOD.sha(b'["abc","7","http","127.0.0.1","1234","owned-fixture-user"]'))
        for key,value in [('revision',8),('id','other')]:
            self.assertNotEqual(MOD.configuration_digest({**profile,key:value}),MOD.configuration_digest(profile))

    def test_owned_file_reads_fail_on_symlink_hardlink_fifo_size_and_public_mode(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);file=root/'data';file.write_bytes(b'{}');file.chmod(0o600)
            self.assertEqual(MOD.read_private(file),b'{}')
            with self.assertRaises(ValueError):MOD.read_private(file,1)
            link=root/'link';link.symlink_to(file)
            with self.assertRaises(OSError):MOD.read_private(link)
            link.unlink();os.link(file,link)
            with self.assertRaises(ValueError):MOD.read_private(file)
            link.unlink();file.chmod(0o644)
            with self.assertRaises(ValueError):MOD.read_private(file)
            fifo=root/'fifo';os.mkfifo(fifo,0o600)
            with self.assertRaises(ValueError):MOD.read_private(fifo)

    def test_existing_receipt_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'receipt';MOD.write_new(path,{'result':'not-a-PASS'})
            original=path.read_bytes()
            with self.assertRaises(FileExistsError):MOD.write_new(path,{'result':'PASS'})
            self.assertEqual(path.read_bytes(),original)
            self.assertEqual(path.stat().st_mode & 0o777,0o600)

    def test_receipts_share_private_fixture_output_not_a_separate_directory(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'private-state.json';path.write_bytes(b'{}');path.chmod(0o600)
            self.assertEqual(MOD.receipt_directory(path),Path(root).resolve())
            os.chmod(root,0o755)
            with self.assertRaises(ValueError):MOD.receipt_directory(path)
            os.chmod(root,0o700)


if __name__=='__main__':unittest.main()
