"""Closed scope and parser controls; no native launch/kernel claims."""
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import uuid

SPEC=importlib.util.spec_from_file_location('webrtc_custody_tests',Path(__file__).resolve().parents[1]/'runtime-network/collect-manager-webrtc.py')
W=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(W)


class ManagerWebRTCCustodyTests(unittest.TestCase):
    def test_owned_state_refuses_other_modes_and_paths(self):
        root=Path('/private/tmp')/('neantik-update-audit-'+str(uuid.uuid4()));root.mkdir(mode=0o700)
        try:
            state=dict(root=str(root),data=str(root/'manager-data'),manifest=str(root/'candidate-manifest.json'),
                       webrtcFixture={'mode':'manager-webrtc'},profiles=[dict(id=str(uuid.uuid4()),name=n) for n in ('QA route proxy','QA route direct')])
            path=root/'state.json';W.CORE.write_new(path,state);self.assertEqual(W.owned_state(path)[1],root)
            for mutate in [lambda x:x['webrtcFixture'].update(mode='manager-dns'),lambda x:x.update(data='/other'),
                           lambda x:x['profiles'][0].update(name='real profile'),lambda x:x['profiles'][0].update(id='wrong')]:
                bad=json.loads(json.dumps(state));mutate(bad);path.write_text(json.dumps(bad))
                with self.assertRaises(ValueError):W.owned_state(path)
        finally:(root/'state.json').unlink();root.rmdir()

    def test_exact_UDP_port_owner_and_ambiguity_controls(self):
        for name in ['*:1234','127.0.0.1:1234','127.0.0.1:1234->127.0.0.1:5555']:
            self.assertEqual(W.udp_socket_owner('p100\nn'+name+'\n',1234,5555),100)
        for listing in ['p100\nn*:1235','p100\nn192.0.2.1:1234','p100\nn127.0.0.1:1234->127.0.0.1:5556',
                        'n*:1234','p100\nn*:1234\np101\nn*:1234','pwrong\nn*:1234']:
            with self.assertRaises(ValueError):W.udp_socket_owner(listing,1234,5555)
        with self.assertRaises(ValueError):W.udp_socket_owner('p100\nn*:1234',True,5555)

    def test_capture_has_distinct_mode_and_exact_kernel_policy(self):
        state={'webrtcFixture':{'mode':'manager-webrtc'}}
        with patch.object(W.CORE,'capture',return_value={'browser':{'pid':20}}),patch.object(W.CORE,'argv_for',return_value=['--webrtc-ip-handling-policy=default']):
            with self.assertRaises(ValueError):W.capture(state,Path('/owned'),'proxy-success')
        with self.assertRaises(ValueError):W.capture(state,Path('/owned'),'dns-refused')
        with self.assertRaises(ValueError):W.CORE.capture(state,Path('/owned'),'proxy-success',physical_tcp=True,manager_webrtc=True)

    def test_normal_exit_observation_is_distinct_from_absent_process(self):
        text='2026-10-16T00:00:00Z browser_launch version=156.0.8078.12\n2026-10-16T00:01:00Z browser_exit reason=1 status=0\n'
        good=W.exit_observation(text,'156.0.8078.12');self.assertEqual(good['terminationStatus'],0)
        self.assertEqual(W.exit_observation(text.replace('reason=1 status=0','reason=2 status=15'),'156.0.8078.12')['terminationReason'],2)
        for altered in [text.replace('browser_exit','missing'),text+text,text.replace('156.0.8078.12','wrong')]:
            with self.assertRaises(ValueError):W.exit_observation(altered,'156.0.8078.12')


if __name__=='__main__':unittest.main()
