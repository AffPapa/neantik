"""Pure custody rejection controls; these never qualify real browser traffic."""
import copy
import importlib.util
import os
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'runtime-network/background-peer-custody.py'
SPEC = importlib.util.spec_from_file_location('background_peer_tests', SOURCE)
MOD = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)


def fixture():
    browser = dict(pid=123, uid=os.getuid(), startSeconds=10, startMicroseconds=20)
    owner = dict(pid=124, uid=os.getuid(), startSeconds=11, startMicroseconds=21)
    relay = dict(ownerPID=124, ownerUID=os.getuid(), ownerStartSeconds=11, ownerStartMicroseconds=21,
                 sessionGeneration='session', loopbackPort=12345, runtimeExecutableSHA256='a'*64, runtimeFrameworkSHA256='b'*64)
    lease = dict(pid=123, schemaVersion=3, phase='running', relay=relay, ownerToken='session', createdAt='date')
    receipt = dict(browserPID=123, ownerPID=124, relayPort=12345, runtimeExecutableSHA256='a'*64, runtimeFrameworkSHA256='b'*64,
                   quitSnapshot=dict(lease=copy.deepcopy(lease), browser=dict(userID=os.getuid(), seconds=10, microseconds=20),
                                     owner=dict(userID=os.getuid(), seconds=11, microseconds=21)))
    return receipt, lease, browser, owner


class BackgroundPeerCustodyTests(unittest.TestCase):
    def test_exact_retained_generations_and_lease_are_admitted(self):
        MOD.validate_binding(*fixture())

    def test_other_client_reused_generation_or_foreign_uid_never_binds(self):
        for item, key, value in [(2,'pid',999), (3,'pid',999), (2,'startSeconds',99),
                                 (3,'startMicroseconds',99), (2,'uid',os.getuid()+1), (3,'uid',os.getuid()+1)]:
            values=list(fixture()); values[item][key]=value
            with self.subTest(item=item,key=key),self.assertRaises(ValueError):MOD.validate_binding(*values)

    def test_changed_lease_or_runtime_cannot_relabel_a_session(self):
        for field,value in [('ownerToken','other'),('phase','starting'),('schemaVersion',2),('futureField',True)]:
            values=list(fixture());values[1][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):MOD.validate_binding(*values)
        for field,value in [('runtimeExecutableSHA256','c'*64),('runtimeFrameworkSHA256','d'*64),('relayPort',23456)]:
            values=list(fixture());values[0][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):MOD.validate_binding(*values)


if __name__ == '__main__':unittest.main()
