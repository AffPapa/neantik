#!/usr/bin/env python3
"""Pure analyzer controls: no listener, native launch, settings or Keychain."""
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("baseline", Path(__file__).with_name("owned-baseline.py"))
QA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QA)
RUN = "00000000-0000-4000-8000-000000000001"


class ObservationTests(unittest.TestCase):
    def setUp(self):
        self.value = {"schemaVersion": 1, "mode": "headed-owned-endpoint", "role": "B", "runID": RUN,
                      "outcome": "loaded", "httpStatus": 200, "uptime": 100, "timestamp": "2026-10-16T10:00:00Z"}

    def parse(self, data=None, **kwargs):
        return QA.parse_observation(data if data is not None else json.dumps(self.value).encode(),
                                    **dict(role="B", run_id=RUN, exit_code=0, timed_out=False, **kwargs))

    def test_matching_single_receipt_and_origin_pass(self):
        self.assertTrue(QA.reached_origin(self.parse(), [{"uptime": 99}]))

    def test_missing_duplicate_or_oversized_receipt_refuses(self):
        raw = json.dumps(self.value).encode()
        for data in (b"", raw + b"\n" + raw, b"x" * 16385):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                self.parse(data)

    def test_foreign_run_or_role_refuses(self):
        for key, value in (("role", "A"), ("runID", "another"), ("schemaVersion", 2)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.parse(json.dumps({**self.value, key: value}).encode())

    def test_failed_exit_and_outer_timeout_refuse_even_good_receipt(self):
        raw = json.dumps(self.value).encode()
        for exit_code, timeout in ((1, False), (0, True)):
            with self.assertRaises(ValueError):
                QA.parse_observation(raw, role="B", run_id=RUN, exit_code=exit_code, timed_out=timeout)

    def test_loaded_without_origin_or_duplicate_origin_is_not_pass(self):
        for events in ([], [{}, {}]):
            self.assertFalse(QA.reached_origin(self.parse(), events))

    def test_typed_error_is_valid_observation_but_not_pass(self):
        self.value.update(outcome="failure", errorDomain="NSURLErrorDomain", errorCode=-1009)
        self.value.pop("httpStatus")
        self.assertFalse(QA.reached_origin(self.parse(), []))

    def test_raw_url_or_unexpected_fields_refuse(self):
        for extra in ({"url": "private"}, {"errorDomain": "raw description"}, {"errorCode": "-1009"}):
            with self.assertRaises(ValueError):
                self.parse(json.dumps({**self.value, **extra}).encode())

    def test_unexpected_http_response_is_not_pass(self):
        self.value.update(outcome="unexpected-response", httpStatus=503)
        self.assertFalse(QA.reached_origin(self.parse(), [{}]))

    def test_contradictory_success_and_untyped_failure_refuse(self):
        for extra in ({"errorCode": -1}, {"httpStatus": 503}, {"outcome": "failure"}, {"timestamp": 42}):
            with self.assertRaises(ValueError):
                self.parse(json.dumps({**self.value, **extra}).encode())


if __name__ == "__main__":
    unittest.main()
