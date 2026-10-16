"""Owned socket/protocol controls, not a browser or route qualification."""
import base64
import importlib.util
import json
from pathlib import Path
import socket
import struct
import tempfile
import unittest
from urllib.parse import urlencode
import uuid

SPEC=importlib.util.spec_from_file_location('webrtc_fixture_tests',Path(__file__).resolve().parents[1]/'runtime-network/manager-webrtc-fixture.py')
W=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(W)


class ManagerWebRTCFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='neantik-webrtc-unit-');self.f=W.ManagerWebRTCFixture(Path(self.temp.name))
        self.f.peer_inspector=lambda channel,direct:{'ownSyntheticPeer':True,'direct':direct}
        self.f.udp_inspector=lambda peer,port:{'ownSyntheticUDP':True}

    def tearDown(self):
        self.assertTrue(self.f.close());self.temp.cleanup()

    def request(self,phase,result=None,protected=True):
        f=self.f;endpoint=f.proxy.server_address if protected else f.origin.server_address
        with socket.create_connection(endpoint,timeout=3) as client:
            client.settimeout(3)
            if protected:
                auth=base64.b64encode((W.BASE.QA_USER+':'+W.BASE.QA_PASSWORD).encode())
                client.sendall(b'CONNECT 127.0.0.1:'+str(f.origin.server_address[1]).encode()+b' HTTP/1.1\r\nProxy-Authorization: Basic '+auth+b'\r\n\r\n')
                self.assertTrue(W.BASE.header(client).startswith(b'HTTP/1.1 200 '))
            query={'phase':phase,'nonce':f.nonces[phase]}
            if result is not None:query['result']=json.dumps(result)
            client.sendall(('GET /owned-route?'+urlencode(query)+' HTTP/1.1\r\nHost: owned\r\n\r\n').encode())
            header=W.BASE.header(client);body=bytearray()
            while chunk:=client.recv(16384):body.extend(chunk)
            return header,bytes(body)

    def result(self,phase):
        return dict(nonce=self.f.nonces[phase],gatheringComplete=True,iceGatheringState='complete',timedOut=False,
                    candidates=dict(host=0,srflx=0,prflx=0,relay=0,other=0),errorCodes=[],rawICEExported=False)

    def test_normal_page_canary_receipt_and_request_link_without_CDP(self):
        f=self.f;header,body=self.request('proxy-success');self.assertIn(b'200 OK',header);self.assertIn(b'OWN_WEBRTC_CONFIG',body)
        header,_=self.request('proxy-success',self.result('proxy-success'));self.assertIn(b'200 OK',header)
        events=f.ledger.events;page=next(e for e in events if e['kind']=='webrtc-page');probe=next(e for e in events if e['kind']=='webrtc-probe')
        self.assertNotIn('nonce',probe['probe'])
        for event,is_receipt in [(page,False),(probe,True)]:
            self.assertTrue(any(e['kind']=='webrtc-upstream-peer' and e['isReceipt']==is_receipt
                and e['requestIDSHA256']==event['peer']['requestIDSHA256'] for e in events))
        self.assertEqual(f.stun['proxy-success'].control,1);self.assertEqual(f.stun['proxy-success'].requests,0)
        header,_=self.request('proxy-success',self.result('proxy-success'));self.assertIn(b'400 Bad Request',header)

    def test_real_UDP_positive_and_final_counters_are_independent_of_page_receipt(self):
        f=self.f;self.request('direct-control',protected=False);server=f.stun['direct-control']
        token=b'test-nonce12';self.assertEqual(len(token),12)
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as client:
            client.settimeout(2);client.sendto(struct.pack('!HHI',1,0,0x2112a442)+token,('127.0.0.1',server.port));reply,_=client.recvfrom(128)
            self.assertEqual(reply[8:20],token)
        header,_=self.request('direct-control',self.result('direct-control'),protected=False);self.assertIn(b'200 OK',header)
        final=server.close();self.assertEqual(final['browserRequests'],1);self.assertEqual(final['invalidRequests'],0);self.assertTrue(final['threadDrained'])
        self.assertTrue(any(e['kind']=='webrtc-udp-peer' for e in f.ledger.events))

    def test_invalid_nonce_fields_wire_and_early_receipt_are_refused(self):
        f=self.f;self.assertIsNone(f.phase('/owned-route?phase=proxy-success&nonce=wrong'))
        self.assertIsNone(f.phase('/owned-route?phase=proxy-success&nonce='+f.nonces['proxy-success']+'&nonce=extra'))
        self.assertIsNone(f.phase('/owned-route?phase=proxy-success&nonce='+f.nonces['proxy-success']+'&extra=true'))
        header,_=self.request('proxy-success',self.result('proxy-success'));self.assertIn(b'400 Bad Request',header)
        good=self.result('proxy-success')
        for change in [lambda x:x.update(nonce='wrong'),lambda x:x.update(rawICEExported=True),
                       lambda x:x.update(rawSDP='forbidden'),lambda x:x['candidates'].update(host=True)]:
            value=json.loads(json.dumps(good));change(value)
            with self.assertRaises(ValueError):W.validate_probe(value,f.nonces['proxy-success'])
        request=struct.pack('!HHI',1,0,0x2112a442)+bytes(12)
        for packet in [request[:19],b'bad'+request,request+b'\0',request[:4]+bytes(4)+request[8:]]:
            with self.assertRaises(ValueError):W.binding_response(packet,1234)

    def test_only_new_owned_profile_receives_permissive_preferences(self):
        data=Path(self.temp.name)/'manager-data';data.mkdir(mode=0o700);profiles=[dict(id=str(uuid.uuid4())) for _ in range(2)]
        self.f.prepare_profiles(data,profiles);file=data/'Profiles'/profiles[0]['id']/'BrowserData/Default/Preferences'
        self.assertEqual(json.loads(file.read_text())['webrtc']['ip_handling_policy'],'default')
        self.assertEqual(file.stat().st_mode&0o777,0o600);self.assertFalse((data/'Profiles'/profiles[1]['id']).exists())
        for parent in file.parents:
            if parent==data:break
            self.assertEqual(parent.stat().st_mode&0o777,0o700)

    def test_favicon_refusal_leaves_empty_origin_connection_not_a_probe_result(self):
        # CONNECT opens the fixture origin before the later HTTP target is
        # checked. A rejected favicon then closes that empty connection.
        f=self.f
        with socket.create_connection(f.proxy.server_address,timeout=3) as client:
            client.settimeout(3);auth=base64.b64encode((W.BASE.QA_USER+':'+W.BASE.QA_PASSWORD).encode())
            client.sendall(b'CONNECT 127.0.0.1:'+str(f.origin.server_address[1]).encode()+b' HTTP/1.1\r\nProxy-Authorization: Basic '+auth+b'\r\n\r\n')
            self.assertTrue(W.BASE.header(client).startswith(b'HTTP/1.1 200 '))
            client.sendall(b'GET /favicon.ico HTTP/1.1\r\nHost: owned\r\n\r\n');self.assertEqual(client.recv(1024),b'')
        import time
        deadline=time.monotonic()+2
        while time.monotonic()<deadline and not any(e['kind']=='webrtc-origin-refused' for e in f.ledger.events):time.sleep(.01)
        kinds=[e['kind'] for e in f.ledger.events]
        self.assertIn('proxy-operation-failure',kinds);self.assertIn('webrtc-origin-refused',kinds)
        self.assertFalse(any(kind in kinds for kind in ('webrtc-page','webrtc-probe','webrtc-stun-control')))


if __name__=='__main__':unittest.main()
