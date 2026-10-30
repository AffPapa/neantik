"""Closed TCP wrapper controls; live kernel evidence remains a separate gate."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT=Path(__file__).resolve().parents[1]/'runtime-network'
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
TCP=module('tcp_custody_tests','collect-manager-tcp.py')
AX=module('tcp_observer_tests','observe-manager-tcp-failure.py')


class ManagerTCPCustodyTests(unittest.TestCase):
    def test_closed_state_does_not_admit_dns_or_other_root(self):
        root=Path('/private/tmp')/('neantik-update-audit-'+str(uuid.uuid4()))
        root.mkdir(mode=0o700)
        try:
            state=dict(root=str(root),data=str(root/'manager-data'),manifest=str(root/'candidate-manifest.json'),
                       tcpFixture={'mode':'manager-physical-tcp'},profiles=[dict(name=name,id=str(uuid.uuid4())) for name in ('QA route proxy','QA route direct')])
            path=root/'state.json';TCP.CORE.write_new(path,state)
            self.assertEqual(TCP.owned_state(path)[1],root)
            for change in [lambda s:s['tcpFixture'].update(mode='manager-dns'),
                           lambda s:s.update(data='/other/data'),lambda s:s['profiles'][0].update(name='ordinary'),
                           lambda s:s['profiles'][0].update(id='invalid'),lambda s:s.update(root=str(root)+'-other')]:
                altered=json.loads(json.dumps(state));change(altered);path.write_text(json.dumps(altered))
                with self.assertRaises((ValueError,OSError)):TCP.owned_state(path)
        finally:
            (root/'state.json').unlink(missing_ok=True);root.rmdir()

    def test_capture_explicitly_selects_tcp_and_rejects_other_phase(self):
        with patch.object(TCP.CORE,'capture',return_value={'phase':'proxy-success'}) as capture:
            result=TCP.capture({},Path('/owned'),'proxy-success')
            capture.assert_called_once_with({},Path('/owned'),'proxy-success',physical_tcp=True)
            self.assertEqual(result['tcpCollectorSHA256'],hashlib.sha256(Path(TCP.__file__).read_bytes()).hexdigest())
        with self.assertRaises(ValueError):TCP.capture({},Path('/owned'),'dns-refused')
        with self.assertRaises(ValueError):TCP.CORE.capture({'tcpFixture':{'mode':'wrong'}},Path('/owned'),'proxy-success',physical_tcp=True)

    def test_retained_cua_observation_keeps_hash_and_live_lease_boundary(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);path=root/'ax.txt';url='http://127.0.0.1:1234/owned-route?nonce=synthetic'
            raw=(url+'\nERR_SOCKS_CONNECTION_FAILED\n').encode();path.write_bytes(raw);path.chmod(0o600)
            state={'urls':{'listener-refused':url}}
            snapshot=dict(manager={'pid':10},browser={'pid':11},relayOwner={'pid':12},leaseSHA256='a'*64,
                          configurationSHA256='b'*64,revision=1,metadataIdentitySHA256='c'*64)
            with patch.object(AX.TCP,'capture',return_value=snapshot):
                receipt=AX.capture(state,root,path)
            self.assertEqual(receipt['reducedAXSHA256'],hashlib.sha256(raw).hexdigest())
            self.assertEqual(receipt['observationMethod'],'operator-owned-CUA-AX')
            changed={**snapshot,'leaseSHA256':'d'*64}
            with patch.object(AX.TCP,'capture',side_effect=[snapshot,changed]),self.assertRaises(ValueError):AX.capture(state,root,path)
            path.chmod(0o644)
            with patch.object(AX.TCP,'capture',return_value=snapshot),self.assertRaises(ValueError):AX.capture(state,root,path)


if __name__=='__main__':unittest.main()
