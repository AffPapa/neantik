"""Pure controls for the exact-hash loopback QA fixture; starts no sockets."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / "runtime-network"
SPEC = importlib.util.spec_from_file_location("shared_broker_qa_fixture", ROOT / "shared-broker-qa-fixture.py")
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
RECIPIENT_SPEC = importlib.util.spec_from_file_location("recipient_qa_fixture", ROOT / "recipient-qa-fixture.py")
RECIPIENT = importlib.util.module_from_spec(RECIPIENT_SPEC)
RECIPIENT_SPEC.loader.exec_module(RECIPIENT)


class ExactProxyAuthorityTests(unittest.TestCase):
    def test_only_configured_connect_authority_is_accepted(self):
        self.assertEqual(FIXTURE.classify_connect_authority(FIXTURE.EXPECTED_HOST, FIXTURE.EXPECTED_HOST), "accepted")
        for authority, host in (
            ("127.0.0.1:45103", FIXTURE.EXPECTED_HOST),
            ("127.0.0.1:45102", "127.0.0.1:45103"),
            ("[::1]:45102", "[::1]:45102"),
            ("127.0.0.1:45102/path", FIXTURE.EXPECTED_HOST),
            ("not an authority", FIXTURE.EXPECTED_HOST),
        ):
            with self.subTest(authority=authority, host=host):
                self.assertEqual(FIXTURE.classify_connect_authority(authority, host), "authority-mismatch")

    def test_tunnel_accepts_only_expected_request_and_host(self):
        self.assertEqual(FIXTURE.classify_tunneled_request("GET /proxy-a HTTP/1.1", FIXTURE.EXPECTED_HOST), "accepted")
        for request, host in (
            ("GET /direct-b HTTP/1.1", FIXTURE.EXPECTED_HOST),
            ("POST /proxy-a HTTP/1.1", FIXTURE.EXPECTED_HOST),
            ("GET /proxy-a?x=1 HTTP/1.1", FIXTURE.EXPECTED_HOST),
            ("GET /proxy-a HTTP/1.1", "127.0.0.1:45103"),
            ("GET /proxy-a HTTP/2", FIXTURE.EXPECTED_HOST),
        ):
            with self.subTest(request=request, host=host):
                self.assertEqual(FIXTURE.classify_tunneled_request(request, host), "request-mismatch")


class RouteEvidenceTests(unittest.TestCase):
    def test_proxy_direct_control_refusal_and_recovery_qualify_only_loopback_route(self):
        events = [
            {"kind": "proxy-response-complete", "authority": FIXTURE.EXPECTED_HOST, "path": "/proxy-a"},
            {"kind": "direct-b-response-complete", "authority": FIXTURE.EXPECTED_HOST, "path": "/direct-b"},
            {"kind": "proxy-refused", "authority": FIXTURE.EXPECTED_HOST, "path": "/proxy-a"},
            {"kind": "proxy-response-complete", "authority": FIXTURE.EXPECTED_HOST, "path": "/proxy-a"},
        ]
        result = FIXTURE.summarize(events)
        self.assertEqual(result["directFallbacks"], 0)
        self.assertEqual(result["proxyRefusals"], 1)
        self.assertIn("visually confirmed", result["result"])

    def test_wrong_authority_bypass_missing_recovery_or_missing_direct_control_refuse(self):
        base = [
            {"kind": "proxy-response-complete", "authority": FIXTURE.EXPECTED_HOST, "path": "/proxy-a"},
            {"kind": "direct-b-response-complete", "authority": FIXTURE.EXPECTED_HOST, "path": "/direct-b"},
            {"kind": "proxy-refused", "authority": FIXTURE.EXPECTED_HOST, "path": "/proxy-a"},
            {"kind": "proxy-response-complete", "authority": FIXTURE.EXPECTED_HOST, "path": "/proxy-a"},
        ]
        mutations = []
        mutations.append(base[:1])
        mutations.append([event for event in base if event["kind"] != "direct-b-response-complete"])
        mutations.append([event for event in base if event["kind"] != "proxy-response-complete"])
        mutations.append(base + [{"kind": "direct-proxy-a-bypass", "authority": FIXTURE.EXPECTED_HOST, "path": "/proxy-a"}])
        mutations.append(base + [{"kind": "proxy-authority-mismatch", "authority": "127.0.0.1:9", "target": "http://127.0.0.1:9/proxy-a"}])
        mutations.append(base + [{"kind": "proxy-response-complete", "authority": "127.0.0.1:9", "path": "/proxy-a"}])
        mutations.append(base + [{"kind": "proxy-tunneled-request-mismatch", "request": "GET /other HTTP/1.1"}])
        mutations.append(base + [{"kind": "proxy-unexpected-credentials"}])
        for i, events in enumerate(mutations):
            with self.subTest(mutation=i), self.assertRaises(FIXTURE.FixtureError):
                FIXTURE.summarize(events)


class DOMPersistenceEvidenceTests(unittest.TestCase):
    def test_dom_mode_adds_only_two_exact_beacon_paths(self):
        prior = FIXTURE.QA_DOM_PERSISTENCE
        try:
            FIXTURE.QA_DOM_PERSISTENCE = True
            for path in ("/proxy-a", "/qa-dom-written", "/qa-dom-restored"):
                self.assertEqual(FIXTURE.classify_tunneled_request(
                    f"GET {path} HTTP/1.1", FIXTURE.EXPECTED_HOST), "accepted")
            for path in ("/qa-dom-other", "/qa-dom-written?x=1", "/direct-b"):
                self.assertEqual(FIXTURE.classify_tunneled_request(
                    f"GET {path} HTTP/1.1", FIXTURE.EXPECTED_HOST), "request-mismatch")
            self.assertIn(b"localStorage.setItem", FIXTURE.proxy_body("/proxy-a"))
            self.assertIn(b"getBoundingClientRect", FIXTURE.proxy_body("/proxy-a"))
        finally:
            FIXTURE.QA_DOM_PERSISTENCE = prior

    def test_dom_restore_requires_two_pages_and_no_bypass(self):
        host = "neantik-proxy-qa.invalid:45102"
        events = [
            {"kind": "proxy-response-complete", "authority": host},
            {"kind": "qa-dom-written", "authority": host},
            {"kind": "proxy-response-complete", "authority": host},
            {"kind": "qa-dom-restored", "authority": host},
        ]
        self.assertEqual(RECIPIENT.verify_dom(events, host)["restored"], 1)
        for altered in (events[:3], events + [{"kind": "direct-proxy-a-bypass"}],
                        [events[0], events[2], events[1], events[3]]):
            with self.assertRaises(ValueError):
                RECIPIENT.verify_dom(altered, host)


if __name__ == "__main__":
    unittest.main()
