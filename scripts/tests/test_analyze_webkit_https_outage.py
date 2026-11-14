from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'runtime-network/analyze-webkit-https-outage.py'
SPEC = importlib.util.spec_from_file_location('analyze_webkit_https_outage', SCRIPT)
QA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QA)


class WebKitHTTPSOutageTests(unittest.TestCase):
    def setUp(self):
        self.before = {'originRouteAttribution': True, 'proxyA': {'refused': 0, 'authenticated': 1},
                       'origin': {'accepted': 1, 'unattributedConnections': 0, 'requestTrace': []}}
        self.during = deepcopy(self.before)
        self.during['proxyA']['refused'] += 1
        self.recovery = deepcopy(self.during)
        self.recovery['proxyA']['authenticated'] += 1
        self.recovery['origin']['accepted'] += 1
        self.recovery['origin']['requestTrace'].append({'category': 'page', 'result': 'responded', 'route': 'A'})

    def test_refusal_and_attributed_recovery(self):
        result = QA.evaluate(self.before, self.during, self.recovery, route='A')
        self.assertEqual(result['status'], 'PASS')
        self.assertFalse(result['browserCustodyVerified'])

    def test_unexercised_refusal_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'proxy-refusal-not-observed'):
            QA.evaluate(self.before, self.before, self.recovery, route='A')

    def test_origin_hit_during_outage_is_rejected_even_without_http(self):
        self.during['origin']['accepted'] += 1
        with self.assertRaisesRegex(ValueError, 'origin-connection-during-refusal'):
            QA.evaluate(self.before, self.during, self.recovery, route='A')

    def test_recovery_over_the_wrong_proxy_is_rejected(self):
        self.recovery['origin']['requestTrace'][0]['route'] = 'B'
        with self.assertRaisesRegex(ValueError, 'unexpected-recovery-route'):
            QA.evaluate(self.before, self.during, self.recovery, route='A')
