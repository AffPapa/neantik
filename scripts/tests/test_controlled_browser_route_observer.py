import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('controlled_route', Path(__file__).resolve().parents[1]/'controlled-browser-route-observer.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class ControlledBrowserRouteObserverTests(unittest.TestCase):
    url = 'https://owned.example.test/one-time-nonce'
    chain = '[socks5://127.0.0.1:12345]'

    def fixture(self):
        names = ['URL_REQUEST_START_JOB', 'HTTP_TRANSACTION_READ_RESPONSE_HEADERS',
                 'HTTP_STREAM_JOB_CONTROLLER_BOUND', 'HTTP_STREAM_JOB_CONTROLLER_PROXY_SERVER_RESOLVED',
                 'HTTP_STREAM_REQUEST_BOUND_TO_JOB', 'HTTP_STREAM_JOB_BOUND_TO_REQUEST',
                 'SOCKET_POOL_BOUND_TO_SOCKET', 'SSL_CONNECT', 'SOCKS5_CONNECT', 'CERT_VERIFY_PROC_CREATED']
        types = {name: i for i, name in enumerate(names, 1)}
        def event(name, sid, params=None, phase=0):
            return {'type': types[name], 'source': {'id': sid}, 'phase': phase, 'params': params or {}}
        return {'constants': {'logCaptureMode': 'Default', 'logEventTypes': types}, 'events': [
            event('URL_REQUEST_START_JOB', 1, {'url': self.url}),
            event('HTTP_TRANSACTION_READ_RESPONSE_HEADERS', 1, {'headers': ['synthetic response']}),
            event('HTTP_STREAM_JOB_CONTROLLER_BOUND', 1, {'source_dependency': {'id': 2}}),
            event('HTTP_STREAM_JOB_CONTROLLER_PROXY_SERVER_RESOLVED', 2, {'proxy_chain': self.chain}),
            event('HTTP_STREAM_REQUEST_BOUND_TO_JOB', 1, {'source_dependency': {'id': 3}}),
            event('HTTP_STREAM_JOB_BOUND_TO_REQUEST', 3, {'source_dependency': {'id': 1}}),
            event('SOCKET_POOL_BOUND_TO_SOCKET', 3, {'source_dependency': {'id': 4}}),
            event('SSL_CONNECT', 4, phase=1),
            event('SSL_CONNECT', 4, {'version': 'TLS 1.3', 'cipher_suite': 4865, 'next_proto': 'h2'}, phase=2),
            event('SOCKS5_CONNECT', 4, phase=1),
            event('SOCKS5_CONNECT', 4, phase=2),
            # M156 casts uint32 source IDs to signed int for NetLog JSON.
            event('CERT_VERIFY_PROC_CREATED', -2147483646, phase=1)]}

    def observe(self, fixture):
        return observer.observe_https_success(fixture, expected_url=self.url, expected_proxy_chain=self.chain)

    def test_positive_and_redacted_output(self):
        result = self.observe(self.fixture())
        self.assertEqual(result['boundTLSConnections'], 1)
        self.assertEqual(result['protocols'], ['h2'])
        self.assertNotIn(self.url, str(result))
        self.assertNotIn('synthetic response', str(result))
        self.assertNotIn(self.chain, str(result))

    def test_missing_contexts_and_uncorrelated_response(self):
        for name in ['URL_REQUEST_START_JOB', 'HTTP_TRANSACTION_READ_RESPONSE_HEADERS',
                     'HTTP_STREAM_JOB_CONTROLLER_BOUND', 'HTTP_STREAM_REQUEST_BOUND_TO_JOB',
                     'HTTP_STREAM_JOB_BOUND_TO_REQUEST', 'SOCKET_POOL_BOUND_TO_SOCKET', 'SSL_CONNECT', 'SOCKS5_CONNECT']:
            with self.subTest(name=name):
                fixture = self.fixture(); code = fixture['constants']['logEventTypes'][name]
                fixture['events'] = [e for e in fixture['events'] if e['type'] != code]
                # A response on another source must not fill the missing one.
                fixture['events'].append({'type': fixture['constants']['logEventTypes']['HTTP_TRANSACTION_READ_RESPONSE_HEADERS'], 'source': {'id': 99}, 'phase': 0})
                with self.assertRaises(observer.RouteObservationError): self.observe(fixture)

    def test_wrong_route_tls_and_request_errors(self):
        for surface in ['route', 'tls', 'request', 'nonce', 'job-owner']:
            with self.subTest(surface=surface):
                fixture = self.fixture(); types = fixture['constants']['logEventTypes']
                for e in fixture['events']:
                    if surface == 'route' and e['type'] == types['HTTP_STREAM_JOB_CONTROLLER_PROXY_SERVER_RESOLVED']: e['params']['proxy_chain'] = '[direct://]'
                    if surface == 'tls' and e['type'] == types['SSL_CONNECT'] and e['phase'] == 2: e['params']['net_error'] = -202
                    if surface == 'request' and e['type'] == types['URL_REQUEST_START_JOB']: e['params']['net_error'] = -7
                    if surface == 'nonce' and e['type'] == types['URL_REQUEST_START_JOB']: e['params']['url'] = self.url+'-other'
                    if surface == 'job-owner' and e['type'] == types['HTTP_STREAM_JOB_BOUND_TO_REQUEST']: e['params']['source_dependency']['id'] = 2
                with self.assertRaises(observer.RouteObservationError): self.observe(fixture)

    def test_ambiguous_or_invalid_id_and_tls_completion(self):
        for sid in [0, True, '4', -(2**31)-1, 2**31]:
            fixture = self.fixture(); fixture['events'][-1]['source']['id'] = sid
            with self.subTest(sid=sid), self.assertRaises(observer.RouteObservationError): self.observe(fixture)
        fixture = self.fixture(); fixture['events'].append(copy.deepcopy(fixture['events'][8]))
        with self.assertRaises(observer.RouteObservationError): self.observe(fixture)
        for error in [0, -7]:
            fixture = self.fixture(); extra = copy.deepcopy(fixture['events'][10]); extra['params']['net_error'] = error
            fixture['events'].append(extra)
            with self.subTest(duplicateSOCKSError=error), self.assertRaises(observer.RouteObservationError): self.observe(fixture)
        for dependency in [True, '3', {'id': 3}, 0]:
            fixture = self.fixture(); fixture['events'][4]['params']['source_dependency']['id'] = dependency
            with self.subTest(dependency=dependency), self.assertRaises(observer.RouteObservationError): self.observe(fixture)

    def test_unsupported_capture_or_expectation(self):
        fixture = self.fixture(); fixture['constants']['logCaptureMode'] = 'IncludeSensitive'
        with self.assertRaises(observer.RouteObservationError): self.observe(fixture)
        with self.assertRaises(observer.RouteObservationError):
            observer.observe_https_success(self.fixture(), expected_url=self.url.replace('https:', 'http:'), expected_proxy_chain=self.chain)

    def test_malformed_tls_values_cannot_be_reported_as_success(self):
        for field, values in {
            'version': [True, False, 1, {}, 'TLS 9', ''],
            'cipher_suite': [True, False, '4865', 0, -1, 65536, 4865.0],
            'net_error': [False, True, '0', 0.0, 1, -(2**31)-1],
            'next_proto': [True, {}, [], 'x'*65],
        }.items():
            for value in values:
                fixture = self.fixture(); fixture['events'][8]['params'][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(observer.RouteObservationError):
                    self.observe(fixture)
        for index in [0, 10]:
            for value in [False, True, '0', 0.0]:
                fixture = self.fixture(); fixture['events'][index]['params']['net_error'] = value
                with self.subTest(index=index, value=value), self.assertRaises(observer.RouteObservationError):
                    self.observe(fixture)

    def test_malformed_type_and_phase_identity_are_not_integer_aliases(self):
        for field, value in [('type', True), ('phase', True), ('phase', 3)]:
            fixture = self.fixture(); fixture['events'][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(observer.RouteObservationError):
                self.observe(fixture)
        fixture = self.fixture(); fixture['constants']['logEventTypes']['URL_REQUEST_START_JOB'] = True
        with self.assertRaises(observer.RouteObservationError): self.observe(fixture)
        fixture = self.fixture(); fixture['constants']['logEventPhase'] = {'PHASE_BEGIN': True, 'PHASE_END': 2}
        with self.assertRaises(observer.RouteObservationError): self.observe(fixture)
        for index in [7, 9]:
            fixture = self.fixture(); extra = copy.deepcopy(fixture['events'][index]); extra['phase'] = 0
            fixture['events'].append(extra)
            with self.subTest(extra=index), self.assertRaises(observer.RouteObservationError): self.observe(fixture)


if __name__ == '__main__': unittest.main()
