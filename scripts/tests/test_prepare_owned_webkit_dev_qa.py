import importlib.util
import json
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-owned-webkit-dev-qa.py"
SPEC = importlib.util.spec_from_file_location("prepare_owned_webkit_dev_qa", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OwnedWebKitDevProducerContracts(unittest.TestCase):
    def test_fixture_requires_two_equal_owner_only_seeds(self):
        with tempfile.TemporaryDirectory(prefix="neantik-qa-unit-", dir="/private/tmp") as directory:
            root = Path(directory)
            current = root / "profiles.json"
            previous = root / "profiles.previous.json"
            current.write_bytes(b"synthetic profiles")
            previous.write_bytes(b"synthetic profiles")
            current.chmod(0o600)
            previous.chmod(0o600)
            self.assertEqual(MODULE.validate_fixture(root), hashlib.sha256(current.read_bytes()).hexdigest())
            previous.write_bytes(b"other profiles")
            with self.assertRaisesRegex(MODULE.ProducerError, "fixture-seed-mismatch"):
                MODULE.validate_fixture(root)

    def test_fixture_tls_scope_uses_only_matching_synthetic_https_origin_and_public_ca(self):
        with tempfile.TemporaryDirectory(prefix="neantik-qa-scope-unit-", dir="/private/tmp") as directory:
            root = Path(directory)
            def profile(name, port):
                return {"name": name, "startURL": "https://abc123.neantik-dns.invalid:45102/",
                        "engine": "webkit", "webKitRuntimeGeneration": "isolatedV1",
                        "proxy": {"kind": "http", "host": "127.0.0.1", "port": port,
                                  "username": ""},
                        "identity": {"seed": port}}
            profiles = {"schemaVersion": 5, "profiles": [
                profile("Owned WebKit A isolation QA", 45103),
                profile("Owned WebKit B isolation QA", 45104),
            ]}
            (root / "profiles.json").write_text(json.dumps(profiles))
            (root / "certificates").mkdir()
            anchor = b"a" * 512
            (root / "certificates/ca.der").write_bytes(anchor)
            self.assertEqual(MODULE.fixture_tls_scope(root),
                             (anchor, "https://abc123.neantik-dns.invalid:45102"))
            profiles["profiles"][1]["startURL"] = "https://different.invalid:443/"
            (root / "profiles.json").write_text(json.dumps(profiles))
            with self.assertRaisesRegex(MODULE.ProducerError, "fixture-tls-origin-mismatch"):
                MODULE.fixture_tls_scope(root)

    def test_fixture_peer_policy_requires_explicit_opposite_bool_values(self):
        with tempfile.TemporaryDirectory(prefix="neantik-qa-peer-", dir="/private/tmp") as directory:
            root = Path(directory)
            (root / "certificates").mkdir()
            (root / "certificates/ca.der").write_bytes(b"a" * 512)
            def make_profile(name, port):
                return {"name": name, "startURL": "https://abc123.neantik-dns.invalid:45102/",
                        "engine": "webkit", "webKitRuntimeGeneration": "isolatedV1",
                        "proxy": {"kind": "http", "host": "127.0.0.1", "port": port, "username": ""},
                        "identity": {"seed": port}}
            for flags, accepted in [([True, False], True), ([False, True], False), ([True, True], False),
                                    ([None, False], False), ([1, False], False), ([True, "false"], False), ([True, None], False)]:
                profiles = [make_profile("Owned WebKit A isolation QA", 45103),
                            make_profile("Owned WebKit B isolation QA", 45104)]
                for profile, flag in zip(profiles, flags):
                    profile["webKitBlockPeerConnections"] = flag
                (root / "profiles.json").write_text(json.dumps({"schemaVersion": 6, "profiles": profiles}))
                if accepted: MODULE.fixture_tls_scope(root)
                else:
                    with self.assertRaises(MODULE.ProducerError): MODULE.fixture_tls_scope(root)

    def test_sealer_passes_exact_fixture_ca_and_origin_into_dev_host_package(self):
        with tempfile.TemporaryDirectory(prefix="neantik-qa-package-unit-", dir="/private/tmp") as directory:
            stage = Path(directory)
            app = stage / "NeAntik.app"
            host = app / MODULE.HOST_RELATIVE
            frameworks = host / "Contents/Frameworks"
            (frameworks / "WebKit.framework").mkdir(parents=True)
            binary = host / "Contents/MacOS/NeAntikWebKitHost"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"qa-host")
            observed = {}

            class Packager:
                @staticmethod
                def package(target_app, host_binary, runtime_frameworks, identity, **kwargs):
                    observed.update(app=target_app, binary=host_binary,
                                    frameworks=runtime_frameworks, identity=identity, **kwargs)
                    destination = target_app / MODULE.HOST_RELATIVE
                    (destination / "Contents/MacOS").mkdir(parents=True)

            anchor = b"fixture public DER bytes"
            origin = "https://abc123.neantik-dns.invalid:45102"
            with mock.patch.object(MODULE, "_module", return_value=Packager), \
                 mock.patch.dict(MODULE.os.environ, {"NEANTIK_WEBKIT_SOURCE_OFFER_ROOT": "fixture-offer",
                                                     "NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256": "b" * 64}):
                MODULE.install_fixture_tls_scope(app, stage, anchor, origin)
            self.assertEqual(observed["identity"], MODULE.IDENTITY)
            self.assertTrue(observed["allow_development_qa"])
            self.assertEqual(observed["qa_tls_anchor_der"], anchor)
            self.assertEqual(observed["qa_tls_origins"], [origin])
            self.assertEqual(observed["source_offer_root"], Path("fixture-offer"))
            self.assertEqual(observed["source_offer_manifest_sha256"], "b" * 64)
            self.assertTrue(observed["binary"].is_relative_to(stage))
            self.assertFalse((stage / "NeAntikWebKitHost.source.app").exists())

    def test_source_offer_digest_requires_matching_root_and_hex_shape(self):
        with mock.patch.dict(MODULE.os.environ, {
                "NEANTIK_WEBKIT_SOURCE_OFFER_ROOT": "fixture-offer",
                "NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256": "a" * 64}, clear=True):
            self.assertEqual(MODULE.source_offer_selection(), (Path("fixture-offer"), "a" * 64))
        with mock.patch.dict(MODULE.os.environ, {
                "NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256": "a" * 64}, clear=True):
            with self.assertRaises(MODULE.ProducerError):
                MODULE.source_offer_selection()
        with mock.patch.dict(MODULE.os.environ, {
                "NEANTIK_WEBKIT_SOURCE_OFFER_ROOT": "fixture-offer",
                "NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256": "not-a-digest"}, clear=True):
            with self.assertRaises(MODULE.ProducerError):
                MODULE.source_offer_selection()

    def test_v508_uses_separate_runtime_offer_and_explicit_evidence(self):
        with tempfile.TemporaryDirectory(prefix='neantik-v508-unit-', dir='/private/tmp') as directory:
            stage = Path(directory); app = stage / 'NeAntik.app'; host = app / MODULE.HOST_RELATIVE
            binary = host / 'Contents/MacOS/NeAntikWebKitHost'; binary.parent.mkdir(parents=True)
            binary.write_bytes(b'host'); (host / 'Contents/Frameworks').mkdir()
            values = {name: stage / name for name in ('runtime', 'offer', 'source', 'baseline', 'modified', 'binding', 'receipt')}
            observed = {}
            class Packager:
                V508_SOURCE_OFFER_SHA256 = 'a' * 64
                @staticmethod
                def PrivateV508Evidence(**kwargs): return kwargs
                @staticmethod
                def package(target, host_binary, runtime, identity, **kwargs):
                    observed.update(runtime=runtime, **kwargs)
            with mock.patch.object(MODULE, '_module', return_value=Packager), \
                 mock.patch.object(MODULE, 'source_offer_selection', return_value=(Path('old-offer'), 'b' * 64)):
                MODULE.install_fixture_tls_scope(app, stage, b'anchor', 'https://owned.invalid:443', values)
            self.assertEqual(observed['runtime'], values['runtime'])
            self.assertEqual(observed['source_offer_root'], values['offer'])
            self.assertEqual(observed['source_offer_manifest_sha256'], 'a' * 64)
            self.assertEqual(observed['private_v508_evidence']['receipt'], values['receipt'])

    def test_retired_139_app_is_refused_before_signing_or_copying(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "NeAntik.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.APP_ID,
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "139",
            }))
            with self.assertRaisesRegex(MODULE.ProducerError, "source-dev-identity-or-build-invalid"):
                MODULE.validate_source_app(app)

    def test_profile_requires_mac_dev_claims_authorized_group_and_unexpired_signer(self):
        certificate = b"synthetic DER certificate"
        claims = {
            "Entitlements": {
                "com.apple.application-identifier": MODULE.APPLICATION_ID,
                "com.apple.developer.team-identifier": MODULE.TEAM,
                "keychain-access-groups": [f"{MODULE.TEAM}.*"],
            },
            "DeveloperCertificates": [certificate],
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
            "Platform": ["OSX"],
            "ProvisionsAllDevices": True,
        }
        with mock.patch.object(MODULE, "IDENTITY", hashlib.sha1(certificate).hexdigest().upper()):
            MODULE.validate_profile_claims(plistlib.dumps(claims))
            claims["Entitlements"]["com.apple.application-identifier"] = f"{MODULE.TEAM}.app.neantik.desktop"
            with self.assertRaisesRegex(MODULE.ProducerError, "dev-profile-claims-mismatch"):
                MODULE.validate_profile_claims(plistlib.dumps(claims))
            claims["Entitlements"]["com.apple.application-identifier"] = MODULE.APPLICATION_ID
            claims["Entitlements"]["keychain-access-groups"] = ["ANOTHERTEAM.*"]
            with self.assertRaisesRegex(MODULE.ProducerError, "dev-profile-claims-mismatch"):
                MODULE.validate_profile_claims(plistlib.dumps(claims))
            claims["Entitlements"]["keychain-access-groups"] = [MODULE.APPLICATION_ID]
            MODULE.validate_profile_claims(plistlib.dumps(claims))
            claims["Platform"] = ["iOS"]
            with self.assertRaisesRegex(MODULE.ProducerError, "dev-profile-claims-mismatch"):
                MODULE.validate_profile_claims(plistlib.dumps(claims))
            claims["Platform"] = ["OSX"]
            claims["ExpirationDate"] = datetime.now(timezone.utc) - timedelta(days=1)
            with self.assertRaisesRegex(MODULE.ProducerError, "dev-profile-expired"):
                MODULE.validate_profile_claims(plistlib.dumps(claims))


if __name__ == "__main__":
    unittest.main()
