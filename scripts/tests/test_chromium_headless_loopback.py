import http.client
import importlib.util
from pathlib import Path
import unittest
from urllib.parse import urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / 'runtime-network' / 'run-chromium-headless-loopback.py'
SPEC = importlib.util.spec_from_file_location('chromium_headless_loopback', SCRIPT)
QA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QA)


class ChromiumHeadlessLoopbackTests(unittest.TestCase):
    def test_manager_preflight_does_not_count_as_a_browser_page_or_recover_route(self):
        with QA.route_fixture('fixture-nonce', manager_preflight=True) as (target, counts, ports, refuse_a):
            def get(path, host):
                conn = http.client.HTTPConnection('127.0.0.1', ports['A'], timeout=2)
                try:
                    conn.request('GET', path, headers={'Host': host})
                    response = conn.getresponse()
                    return response.status, response.read()
                finally:
                    conn.close()

            health = 'http://neantik-probe.invalid/health'
            host = 'neantik-probe.invalid'
            self.assertEqual(urlsplit(target).hostname, 'neantik-fixture-nonce.invalid')
            self.assertEqual(get(health, host), (200, b'NEANTIK_LOOPBACK_QA_OK\n'))
            self.assertEqual(get(health, 'wrong.invalid')[0], 403)
            self.assertEqual(counts, dict(A=0, B=0, direct=0, refused=0, preflight=1))
            refuse_a.set()
            self.assertEqual(get(health, host)[0], 200)
            self.assertEqual(get(target, urlsplit(target).netloc)[0], 502)
            self.assertEqual(counts, dict(A=0, B=0, direct=0, refused=1, preflight=2))
            refuse_a.clear()
            self.assertEqual(get(target, urlsplit(target).netloc)[0], 200)
            self.assertEqual(counts, dict(A=1, B=0, direct=0, refused=1, preflight=2))

    def test_proxy_refusal_and_recovery_keep_direct_origin_measurable(self):
        with QA.route_fixture('fixture-nonce') as (target, counts, ports, refuse_a):
            url = urlsplit(target)

            def get(port, path):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
                try:
                    conn.request('GET', path, headers={'Host': url.netloc})
                    response = conn.getresponse()
                    return response.status, response.read()
                finally:
                    conn.close()

            status, payload = get(url.port, '/')
            self.assertEqual(status, 200)
            self.assertIn(b'fixture-nonce:', payload)
            self.assertEqual(get(ports['A'], target)[0], 200)
            self.assertEqual(get(ports['B'], target)[0], 200)
            refuse_a.set()
            self.assertEqual(get(ports['A'], target)[0], 502)
            self.assertEqual(counts, dict(A=1, B=1, direct=1, refused=1))
            self.assertEqual(get(url.port, '/')[0], 200)
            refuse_a.clear()
            self.assertEqual(get(ports['A'], target)[0], 200)
            self.assertEqual(counts, dict(A=2, B=1, direct=2, refused=1))
