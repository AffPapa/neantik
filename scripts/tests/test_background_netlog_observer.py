import copy
import importlib.util
from pathlib import Path
import unittest

p=Path(__file__).resolve().parents[1]/'controlled-browser-route-observer.py'
s=importlib.util.spec_from_file_location('background_observer',p)
observer=importlib.util.module_from_spec(s);s.loader.exec_module(observer)

class BackgroundNetLogObserverTests(unittest.TestCase):
    chain='[socks5://127.0.0.1:12345]'
    def fixture(self):
        names=['URL_REQUEST_START_JOB','HTTP_STREAM_JOB_CONTROLLER_BOUND',
               'HTTP_STREAM_JOB_CONTROLLER_PROXY_SERVER_RESOLVED','HTTP_TRANSACTION_READ_RESPONSE_HEADERS']
        def event(name,sid,params=None,phase=0):
            return {'type':names.index(name),'source':{'id':sid},'phase':phase,'params':params or {}}
        return {'constants':{'logCaptureMode':'Default','logEventTypes':dict(zip(names,range(len(names))))},'events':[
            event(names[0],1,{'url':'http://owned.test/nonce?private-token=synthetic'},1),
            event(names[1],1,{'source_dependency':{'id':2}}),
            event(names[2],2,{'proxy_chain':self.chain}),event(names[3],1,{'headers':'private synthetic header'}),
            event(names[0],3,{'url':'https://clients2.google.com/private'},1),
            event(names[1],3,{'source_dependency':{'id':4}}),
            event(names[2],4,{'proxy_chain':'[direct://]'}),event(names[0],3,{'net_error':-105},2),
            event(names[0],5,{'url':'https://unclassified.example/private'},1)]}
    def observe(self,v):
        return observer.observe_background_attempts(v,expected_proxy_chain=self.chain,owned_fixture_host='owned.test')
    def test_routes_and_unknown_are_separate_and_redacted(self):
        r=self.observe(self.fixture())
        self.assertEqual(r['destinations']['ownedFixture']['selectedRoutes']['expectedRelay'],1)
        self.assertEqual(r['destinations']['vendorRelated']['selectedRoutes']['direct'],1)
        self.assertEqual(r['destinations']['vendorRelated']['failed'],1)
        self.assertEqual(r['destinations']['unclassified']['selectedRoutes']['unobserved'],1)
        self.assertFalse(r['generalPrivacyQualified']);self.assertFalse(r['successfulSocketRouteVerified'])
        for raw in ('owned.test','google.com','unclassified.example','private-token','synthetic header',self.chain):
            self.assertNotIn(raw,str(r))
    def test_missing_context_and_direct_negative_control_cannot_be_expected_relay(self):
        for mutation in ('missing','direct','other','mixed'):
            v=self.fixture()
            if mutation=='missing':v['events'].pop(2)
            elif mutation=='direct':v['events'][2]['params']['proxy_chain']='[direct://]'
            elif mutation=='other':v['events'][2]['params']['proxy_chain']='[socks5://127.0.0.1:23456]'
            else:
                e=copy.deepcopy(v['events'][2]);e['params']['proxy_chain']='[direct://]';v['events'].append(e)
            with self.subTest(mutation=mutation):
                r=self.observe(v)['destinations']['ownedFixture']['selectedRoutes']
                self.assertEqual(r['expectedRelay'],0)
                self.assertEqual(r[{'missing':'unobserved','direct':'direct','other':'other','mixed':'mixed'}[mutation]],1)
    def test_redirect_leg_does_not_borrow_previous_route(self):
        v=self.fixture();e=copy.deepcopy(v['events'][0]);e['params']['url']='https://owned.test/redirect';v['events'].append(e)
        r=self.observe(v)['destinations']['ownedFixture']
        self.assertEqual(r['attempts'],2);self.assertEqual(r['selectedRoutes']['expectedRelay'],1)
        self.assertEqual(r['selectedRoutes']['unobserved'],1)
    def test_controller_selection_cannot_be_borrowed_from_another_redirect_leg(self):
        v=self.fixture()
        v['events']=v['events'][:4]
        start=copy.deepcopy(v['events'][0]);start['params']['url']='https://owned.test/redirect'
        binding=copy.deepcopy(v['events'][1]);selection=copy.deepcopy(v['events'][2])
        selection['params']['proxy_chain']='[direct://]'
        v['events'] += [start,binding,selection]
        result=self.observe(v)['destinations']['ownedFixture']['selectedRoutes']
        self.assertEqual(result['expectedRelay'],1);self.assertEqual(result['direct'],1)
        self.assertEqual(result['mixed'],0)
        del v['events'][2]
        result=self.observe(v)['destinations']['ownedFixture']['selectedRoutes']
        self.assertEqual(result['expectedRelay'],0);self.assertEqual(result['unobserved'],1)
        self.assertEqual(result['direct'],1)

    def test_invalid_private_or_ambiguous_inputs_refuse(self):
        for mutation in ('capture','dependency','credentials','url','chain'):
            v=self.fixture()
            if mutation=='capture':v['constants']['logCaptureMode']='IncludeSensitive'
            elif mutation=='dependency':v['events'][1]['params']['source_dependency']['id']=True
            elif mutation=='credentials':v['events'][0]['params']['url']='http://user:password@owned.test/'
            elif mutation=='url':v['events'][0]['params']['url']=False
            else:v['events'][2]['params']['proxy_chain']=False
            with self.subTest(mutation=mutation),self.assertRaises(observer.RouteObservationError):self.observe(v)
        with self.assertRaises(observer.RouteObservationError):self.observe({'constants':{},'events':[]})

if __name__=='__main__':unittest.main()
