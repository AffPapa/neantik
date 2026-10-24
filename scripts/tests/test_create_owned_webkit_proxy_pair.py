import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path

from scripts.create_owned_webkit_proxy_pair import (
    ProxyPairFixtureError,
    create_pair,
    verify_pair,
)


class CreateOwnedWebKitProxyPairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="owned-webkit-pair-")
        self.root = Path(self.temp.name)
        self.template = self.root / "template.json"
        self.profile_name = "QA isolated WebKit blank 20261021"
        profile = {
            "id": str(uuid.uuid4()).upper(),
            "name": self.profile_name,
            "engine": "webkit",
            "webKitRuntimeGeneration": "isolatedV1",
            "startURL": "about:blank",
            "proxy": None,
            "identity": {
                "catalogVersion": 1,
                "issuanceVersion": 2,
                "seed": 2045354982,
                "deviceTupleID": "macbook-air-m1",
            },
        }
        self.template.write_text(json.dumps({"schemaVersion": 5, "profiles": [profile]}), encoding="utf-8")
        self.output_root = self.root / "qa"
        self.output_root.mkdir(mode=0o700)
        os.chmod(self.output_root, 0o700)

    def tearDown(self):
        self.temp.cleanup()

    def test_creates_exact_owned_proxy_a_and_direct_b_pair(self):
        result = create_pair(self.template, self.output_root, profile_name_prefix="Run QA",
                             proxy_port=45101, origin_port=45102)
        self.assertEqual(result["status"], "PASS")
        self.assertTrue(result["sharedSyntheticIdentityForA_B"])
        path = self.output_root / "profiles.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(verify_pair(path, profile_name_prefix="Run QA",
                                     proxy_port=45101, origin_port=45102), result)

    def test_rejects_system_webkit_template_before_writing(self):
        document = json.loads(self.template.read_text())
        document["profiles"][0]["webKitRuntimeGeneration"] = "system"
        self.template.write_text(json.dumps(document))
        with self.assertRaisesRegex(ProxyPairFixtureError, "isolated_template_rejected"):
            create_pair(self.template, self.output_root, profile_name_prefix="Run QA",
                        proxy_port=45101, origin_port=45102)
        self.assertFalse((self.output_root / "profiles.json").exists())

    def test_rejects_existing_store_without_replacing_it(self):
        path = self.output_root / "profiles.json"
        path.write_text("preserve")
        with self.assertRaisesRegex(ProxyPairFixtureError, "refusing_existing_profile_store"):
            create_pair(self.template, self.output_root, profile_name_prefix="Run QA",
                        proxy_port=45101, origin_port=45102)
        self.assertEqual(path.read_text(), "preserve")

    def test_rejects_wrong_proxy_port(self):
        create_pair(self.template, self.output_root, profile_name_prefix="Run QA",
                    proxy_port=45101, origin_port=45102)
        with self.assertRaisesRegex(ProxyPairFixtureError, "proxy_A_must_match_exact_loopback_fixture"):
            verify_pair(self.output_root / "profiles.json", profile_name_prefix="Run QA",
                        proxy_port=45103, origin_port=45102)

    def test_rejects_direct_profile_with_proxy(self):
        create_pair(self.template, self.output_root, profile_name_prefix="Run QA",
                    proxy_port=45101, origin_port=45102)
        path = self.output_root / "profiles.json"
        document = json.loads(path.read_text())
        document["profiles"][1]["proxy"] = {
            "kind": "http", "host": "127.0.0.1", "port": 45101, "username": ""
        }
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(ProxyPairFixtureError, "direct_B_must_have_no_proxy"):
            verify_pair(path, profile_name_prefix="Run QA", proxy_port=45101, origin_port=45102)


if __name__ == "__main__":
    unittest.main()
