import ast
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
import urllib.request
from http.server import BaseHTTPRequestHandler


SCRIPT = Path(__file__).resolve().parents[1] / 'probe-owned-runtime-webdriver.py'


class OwnedRuntimeProbeTests(unittest.TestCase):
    def test_download_response_is_owned_fixed_attachment(self):
        tree = ast.parse(SCRIPT.read_text())
        page = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'Page')
        scope = {'BaseHTTPRequestHandler': BaseHTTPRequestHandler}
        exec(compile(ast.Module(body=[page], type_ignores=[]), str(SCRIPT), 'exec'), scope)
        handler = object.__new__(scope['Page'])
        handler.path = '/owned-download.txt'
        handler.wfile = io.BytesIO()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        handler.do_GET()
        handler.send_response.assert_called_once_with(200)
        handler.send_header.assert_any_call('Content-Disposition', 'attachment; filename="owned-download.txt"')
        self.assertEqual(handler.wfile.getvalue(), b'NeAntik synthetic download\n')

    def test_extension_is_loopback_only_without_privileged_permissions(self):
        manifest = json.loads((SCRIPT.parent / 'fixtures/owned-runtime-extension/manifest.json').read_text())
        self.assertEqual(manifest['manifest_version'], 3)
        self.assertNotIn('permissions', manifest)
        self.assertNotIn('host_permissions', manifest)
        self.assertEqual(manifest['content_scripts'][0]['matches'], ['http://127.0.0.1/*'])

    def request_scope(self, responses):
        tree = ast.parse(SCRIPT.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'request')
        opener = Mock()
        opener.open.side_effect = [io.StringIO(json.dumps(value)) for value in responses]
        scope = {'json': json, 'urllib': urllib,
                 'base': 'http://127.0.0.1:12345', 'opener': opener,
                 'options': SimpleNamespace(expected_version='153.0.8010.36')}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(SCRIPT), 'exec'), scope)
        return scope, opener

    def test_session_requires_exact_measured_version(self):
        value = {'value': {'sessionId': 'synthetic', 'capabilities': {'browserVersion': '153.0.8010.36'}}}
        scope, opener = self.request_scope([value])
        self.assertEqual(scope['request']('POST', '/session', {}), value)
        self.assertEqual(opener.open.call_count, 1)

    def test_wrong_or_missing_version_closes_created_session(self):
        for capabilities in ({}, {'browserVersion': '152.0.7977.82'}):
            with self.subTest(capabilities=capabilities):
                scope, opener = self.request_scope([
                    {'value': {'sessionId': 'synthetic', 'capabilities': capabilities}},
                    {'value': None}])
                with self.assertRaisesRegex(RuntimeError, 'Measured browser version'):
                    scope['request']('POST', '/session', {})
                last = opener.open.call_args_list[-1].args[0]
                self.assertEqual(last.get_method(), 'DELETE')
                self.assertEqual(last.full_url, 'http://127.0.0.1:12345/session/synthetic')

    def test_non_session_response_is_not_mistaken_for_version_evidence(self):
        scope, _ = self.request_scope([{'value': 'synthetic title'}])
        self.assertEqual(scope['request']('GET', '/session/synthetic/title'), {'value': 'synthetic title'})

    def test_checks_cannot_be_disabled_with_python_optimization(self):
        tree = ast.parse(SCRIPT.read_text())
        self.assertFalse(any(isinstance(node, ast.Assert) for node in ast.walk(tree)))

    def test_identity_binds_driver_and_both_runtime_executables(self):
        tree = ast.parse(SCRIPT.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'runtime_identity')
        scope = {'file_hash': lambda path: 'hash-' + path,
                 'RUNTIME': 'main', 'FRAMEWORK': 'framework',
                 'options': SimpleNamespace(driver='driver', expected_version='153.0.8010.36')}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(SCRIPT), 'exec'), scope)
        self.assertEqual(scope['runtime_identity'](), {
            'mainSHA256': 'hash-main', 'frameworkSHA256': 'hash-framework',
            'driverSHA256': 'hash-driver', 'expectedVersion': '153.0.8010.36'})
