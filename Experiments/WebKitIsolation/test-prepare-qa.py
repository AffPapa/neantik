#!/usr/bin/env python3
"""Pure packaging controls; never sign, launch or access an App Group."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("qa_preparation", Path(__file__).with_name("prepare-qa.py"))
QA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QA)


class MachServiceContractTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleIdentifier": QA.BASE + ".proxy",
                     "NetworkExtension": {"NEMachServiceName": QA.QA_GROUP + ".proxy"}}
        self.claims = {"com.apple.security.application-groups": [QA.QA_GROUP]}

    def test_exact_group_accepts(self):
        QA.validate_network_service(self.info, self.claims)

    def test_previous_missing_group_refuses(self):
        with self.assertRaises(ValueError):
            QA.validate_network_service(self.info, {})

    def test_wrong_or_broader_group_refuses(self):
        for groups in ([], ["other"], [QA.QA_GROUP, "production"], QA.QA_GROUP):
            with self.subTest(groups=groups), self.assertRaises(ValueError):
                QA.validate_network_service(self.info, {"com.apple.security.application-groups": groups})

    def test_service_mismatch_refuses(self):
        for name in (None, "", QA.QA_GROUP + ".proxy.other", "other." + QA.QA_GROUP + ".proxy"):
            info = copy.deepcopy(self.info)
            info["NetworkExtension"]["NEMachServiceName"] = name
            with self.subTest(name=name), self.assertRaises(ValueError):
                QA.validate_network_service(info, self.claims)

    def test_keychain_claim_refuses(self):
        with self.assertRaises(ValueError):
            QA.validate_network_service(self.info, {**self.claims, "keychain-access-groups": []})


if __name__ == "__main__":
    unittest.main()
