import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_owned_webkit_profile import ProfileFixtureError, inspect_profile_store


class VerifyOwnedWebKitProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="owned-webkit-profile-test-")
        self.root = Path(self.temporary.name)
        self.profile = {
            "id": str(uuid.uuid4()),
            "name": "QA owned WebKit",
            "engine": "webkit",
            "webKitRuntimeGeneration": "isolatedV1",
            "startURL": "about:blank",
            "proxy": None,
        }
        self.document = {"schemaVersion": 5, "profiles": [self.profile]}
        self.path = self.root / "profiles.json"
        self.write()

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, text=None):
        self.path.write_text(
            text if text is not None else json.dumps(self.document), encoding="utf-8"
        )

    def test_exact_persisted_owned_profile_passes(self):
        result = inspect_profile_store(self.root, "QA owned WebKit")
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["webKitRuntimeGeneration"], "isolatedV1")
        self.assertFalse(result["proxyConfigured"])

    def test_system_webkit_default_is_rejected(self):
        self.profile["webKitRuntimeGeneration"] = "system"
        self.write()
        with self.assertRaisesRegex(ProfileFixtureError, "profile_runtime_generation_mismatch"):
            inspect_profile_store(self.root, "QA owned WebKit")

    def test_wrong_engine_is_rejected(self):
        self.profile["engine"] = "chromium"
        self.write()
        with self.assertRaisesRegex(ProfileFixtureError, "profile_engine_mismatch"):
            inspect_profile_store(self.root, "QA owned WebKit")

    def test_proxy_profile_is_rejected_without_printing_credentials(self):
        self.profile["proxy"] = {"host": "127.0.0.1", "password": "synthetic-secret"}
        self.write()
        with self.assertRaisesRegex(ProfileFixtureError, "profile_proxy_must_be_absent") as error:
            inspect_profile_store(self.root, "QA owned WebKit")
        self.assertNotIn("synthetic-secret", str(error.exception))

    def test_ambiguous_profile_name_is_rejected(self):
        self.document["profiles"].append({**self.profile, "id": str(uuid.uuid4())})
        self.write()
        with self.assertRaisesRegex(ProfileFixtureError, "profile_name_missing_or_ambiguous"):
            inspect_profile_store(self.root, "QA owned WebKit")

    def test_pre_runtime_schema_is_rejected(self):
        self.document["schemaVersion"] = 4
        self.write()
        with self.assertRaisesRegex(ProfileFixtureError, "profile_store_schema_invalid"):
            inspect_profile_store(self.root, "QA owned WebKit")

    def test_duplicate_json_key_is_rejected(self):
        self.write('{"schemaVersion":5,"schemaVersion":5,"profiles":[]}')
        with self.assertRaisesRegex(ProfileFixtureError, "duplicate_json_key"):
            inspect_profile_store(self.root, "QA owned WebKit")


if __name__ == "__main__":
    unittest.main()
