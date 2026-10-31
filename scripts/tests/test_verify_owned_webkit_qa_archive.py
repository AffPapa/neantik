import hashlib
import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "qa_archive_preflight", Path(__file__).resolve().parents[1] / "verify_owned_webkit_qa_archive.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class OwnedWebKitQAArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.archive = self.root / "qa.zip"
        self.fixture_temp = tempfile.TemporaryDirectory(prefix="neantik-qa-fixture-", dir="/private/tmp")
        self.fixture_root = Path(self.fixture_temp.name)
        self.fixture = str(self.fixture_root)
        self.app_info = {
            "CFBundleIdentifier": "app.neantik.desktop.dev",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "139",
            "CFBundleExecutable": "NeAntik",
            "NeAntikDevelopmentFixtureRoot": self.fixture,
        }
        self.anchor = b"synthetic fixture CA DER bytes"
        self.origin = "https://abc123.neantik-dns.invalid:45102"
        self.host_info = {"CFBundleIdentifier": "app.neantik.desktop.dev.webkit-host",
                          "CFBundleExecutable": "NeAntikWebKitHost",
                          "NeAntikQATrustScope": {"anchorDER": self.anchor,
                                                  "origins": [self.origin]},
                          "NSAppTransportSecurity": {"NSExceptionDomains": {
                              "127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True},
                              "neantik-proxy-qa.invalid": {"NSExceptionAllowsInsecureHTTPLoads": True},
                              "neantik-second-qa.invalid": {"NSExceptionAllowsInsecureHTTPLoads": True},
                              "abc123.neantik-dns.invalid": {
                                  "NSExceptionAllowsInsecureHTTPLoads": True}}}}
        self.manager = b"manager-bytes"
        self.host = b"host-bytes"
        (self.fixture_root / "certificates").mkdir(mode=0o700)
        (self.fixture_root / "certificates/ca.der").write_bytes(self.anchor)
        (self.fixture_root / "certificates/ca.der").chmod(0o644)
        self.profile_seed = (json.dumps({"schemaVersion": 5, "profiles": [
            {"startURL": self.origin + "/"}, {"startURL": self.origin + "/"},
        ]}, sort_keys=True, separators=(",", ":")) + "\n").encode()
        for name in ("profiles.json", "profiles.previous.json"):
            path = self.fixture_root / name
            path.write_bytes(self.profile_seed)
            path.chmod(0o600)
        self.fixture_seed_sha = hashlib.sha256(self.profile_seed).hexdigest()
        self.entries = {
            "NeAntik.app/Contents/Info.plist": plistlib.dumps(self.app_info),
            "NeAntik.app/Contents/MacOS/NeAntik": self.manager,
            "NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/Info.plist": plistlib.dumps(self.host_info),
            "NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/MacOS/NeAntikWebKitHost": self.host,
            "NeAntik.app/Contents/Resources/NeAntikRuntimeNotices.md": b"notices",
        }
        prefix = "NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/Frameworks/"
        for path in (
            "WebKit.framework/Versions/A/WebKit",
            "JavaScriptCore.framework/Versions/A/JavaScriptCore",
            "WebCore.framework/Versions/A/WebCore",
            "WebKitLegacy.framework/Versions/A/WebKitLegacy",
        ):
            self.entries[prefix + path] = b"runtime"
        self.write_archive()
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.candidate = {
            "archive": str(self.archive), "sha256": self.digest, "root": self.fixture,
            "app": str(self.root / "NeAntik.app"), "version": "1.0.0", "build": "139",
            "profileSeedSHA256": self.fixture_seed_sha,
            "managerSignedSHA256": hashlib.sha256(self.manager).hexdigest(),
            "hostSHA256": hashlib.sha256(self.host).hexdigest(),
            "qaTrustAnchorSHA256": hashlib.sha256(self.anchor).hexdigest(),
            "qaTrustOrigin": self.origin,
        }
        self.plan = {"archiveSHA256": self.digest, "root": self.fixture,
                     "profileSeedSHA256": self.candidate["profileSeedSHA256"],
                     "qaTrustAnchorSHA256": self.candidate["qaTrustAnchorSHA256"],
                     "qaTrustOrigin": self.origin}

    def tearDown(self):
        self.temp.cleanup()
        self.fixture_temp.cleanup()

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w", compression=zipfile.ZIP_STORED) as zf:
            for name, data in self.entries.items():
                zf.writestr(name, data)

    def prepare_v508(self):
        self.app_info["NeAntikPrivateQARuntimeVariant"] = "V508"
        self.entries["NeAntik.app/Contents/Info.plist"] = plistlib.dumps(self.app_info)
        host = "NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/"
        self.gpu_path = host + "Frameworks/WebGPU.framework/Versions/A/WebGPU"
        self.binding_path = host + "Resources/NeAntikRuntimeEvidence/NeAntikRuntimeImageBinding.json"
        self.entries[self.gpu_path] = b"synthetic-gpu"
        self.entries[self.binding_path] = b"synthetic-binding"
        gpu_sha = hashlib.sha256(self.entries[self.gpu_path]).hexdigest()
        binding_sha = hashlib.sha256(self.entries[self.binding_path]).hexdigest()
        self.gpu_pin = mock.patch.object(MOD, "V508_WEBGPU_SHA256", gpu_sha)
        self.binding_pin = mock.patch.object(MOD, "V508_BINDING_SHA256", binding_sha)
        self.gpu_pin.start(); self.binding_pin.start()
        self.addCleanup(self.gpu_pin.stop); self.addCleanup(self.binding_pin.stop)
        for item in (self.candidate, self.plan):
            item.update(qaRuntimeVariant="V508", qaWebGPUSHA256=gpu_sha,
                        qaRuntimeBindingSHA256=binding_sha)
        self.plan.update(hostSHA256=self.candidate["hostSHA256"],
                         managerSignedSHA256=self.candidate["managerSignedSHA256"])
        self.reseal_fixture()

    def reseal_fixture(self):
        self.write_archive()
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def test_exact_archive_is_bound_to_fixture_manager_host_and_runtime(self):
        result = MOD.inspect(self.candidate, self.plan)
        self.assertEqual(result["status"], "PASS")
        self.assertTrue(result["fixtureRootBound"])
        self.assertTrue(result["managerAndHostBytesMatch"])

    def test_v508_requires_exact_archive_gpu_binding_and_both_plan_hashes(self):
        self.prepare_v508()
        result = MOD.inspect(self.candidate, self.plan)
        self.assertEqual(result["qaRuntimeVariant"], "V508")
        self.assertTrue(result["qaWebGPUAndBindingBytesMatch"])
        for key in ("hostSHA256", "managerSignedSHA256"):
            saved = self.plan[key]; self.plan[key] = "0" * 64
            with self.assertRaises(MOD.PreflightError): MOD.inspect(self.candidate, self.plan)
            self.plan[key] = saved
        for key in ("qaWebGPUSHA256", "qaRuntimeBindingSHA256"):
            saved = self.plan[key]; self.plan[key] = "0" * 64
            with self.assertRaisesRegex(MOD.PreflightError, "qa-v508-candidate-plan-identity-mismatch"):
                MOD.inspect(self.candidate, self.plan)
            self.plan[key] = saved

    def test_v508_rejects_changed_or_missing_gpu_and_binding_even_if_zip_hash_updated(self):
        self.prepare_v508()
        for path in (self.gpu_path, self.binding_path):
            original = self.entries[path]
            for replacement in (b"changed", None):
                if replacement is None: del self.entries[path]
                else: self.entries[path] = replacement
                self.reseal_fixture()
                with self.assertRaises(MOD.PreflightError): MOD.inspect(self.candidate, self.plan)
            self.entries[path] = original
        self.reseal_fixture()
        self.assertEqual(MOD.inspect(self.candidate, self.plan)["status"], "PASS")

    def test_v508_cannot_be_selected_unilaterally_or_as_unknown_variant(self):
        self.prepare_v508()
        self.plan.pop("qaRuntimeVariant")
        with self.assertRaisesRegex(MOD.PreflightError, "qa-runtime-variant-mismatch"):
            MOD.inspect(self.candidate, self.plan)
        self.plan["qaRuntimeVariant"] = self.candidate["qaRuntimeVariant"] = "OTHER"
        with self.assertRaisesRegex(MOD.PreflightError, "qa-runtime-variant-mismatch"):
            MOD.inspect(self.candidate, self.plan)
        self.plan.pop("qaRuntimeVariant"); self.candidate.pop("qaRuntimeVariant")
        with self.assertRaisesRegex(MOD.PreflightError, "qa-v508-fields-without-variant"):
            MOD.inspect(self.candidate, self.plan)

    def test_v508_signed_app_marker_prevents_variant_downgrade(self):
        self.prepare_v508()
        self.app_info.pop("NeAntikPrivateQARuntimeVariant")
        self.entries["NeAntik.app/Contents/Info.plist"] = plistlib.dumps(self.app_info)
        self.reseal_fixture()
        with self.assertRaisesRegex(MOD.PreflightError, "qa-runtime-variant-app-marker-mismatch"):
            MOD.inspect(self.candidate, self.plan)
        self.app_info["NeAntikPrivateQARuntimeVariant"] = "V508"
        self.entries["NeAntik.app/Contents/Info.plist"] = plistlib.dumps(self.app_info)
        self.reseal_fixture()
        for obj in (self.candidate, self.plan):
            for key in ("qaRuntimeVariant", "qaWebGPUSHA256", "qaRuntimeBindingSHA256"):
                obj.pop(key)
        with self.assertRaisesRegex(MOD.PreflightError, "qa-runtime-variant-app-marker-mismatch"):
            MOD.inspect(self.candidate, self.plan)

    def test_v508_rejects_duplicate_and_symlink_entries(self):
        self.prepare_v508()
        with zipfile.ZipFile(self.archive, "a") as zf:
            zf.writestr(self.gpu_path, b"duplicate")
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(MOD.PreflightError, "duplicate-archive-path"):
            MOD.inspect(self.candidate, self.plan)
        self.reseal_fixture()
        with zipfile.ZipFile(self.archive) as zf:
            payloads = {item.filename: zf.read(item) for item in zf.infolist()}
        with zipfile.ZipFile(self.archive, "w") as zf:
            for name, data in payloads.items():
                info = zipfile.ZipInfo(name)
                if name == self.gpu_path:
                    info.create_system = 3; info.external_attr = 0o120777 << 16
                zf.writestr(info, data)
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(MOD.PreflightError, "qa-v508-archive-entry-invalid"):
            MOD.inspect(self.candidate, self.plan)

    def test_schema_six_peer_control_rejects_missing_or_ambiguous_policies(self):
        for flags, accepted in [([True, False], True), ([False, True], False), ([True, True], False),
                                ([None, False], False), ([1, False], False), ([True, "false"], False)]:
            profiles = [{"startURL": self.origin + "/"}, {"startURL": self.origin + "/"}]
            for profile, flag in zip(profiles, flags):
                profile["webKitBlockPeerConnections"] = flag
            seed = json.dumps({"schemaVersion": 6, "profiles": profiles}).encode()
            for name in ("profiles.json", "profiles.previous.json"):
                (self.fixture_root / name).write_bytes(seed)
            digest = hashlib.sha256(seed).hexdigest()
            if accepted: MOD._fixture_scope(self.fixture_root, digest)
            else:
                with self.assertRaises(MOD.PreflightError): MOD._fixture_scope(self.fixture_root, digest)

    def test_missing_fixture_root_is_refused_before_submission(self):
        self.app_info.pop("NeAntikDevelopmentFixtureRoot")
        self.entries["NeAntik.app/Contents/Info.plist"] = plistlib.dumps(self.app_info)
        self.write_archive()
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(MOD.PreflightError, "embedded-root-mismatch"):
            MOD.inspect(self.candidate, self.plan)

    def test_non_private_or_traversing_fixture_root_is_refused(self):
        self.candidate["root"] = self.plan["root"] = "/private/tmp/neantik-../outside"
        with self.assertRaisesRegex(MOD.PreflightError, "invalid-fixture-root"):
            MOD.inspect(self.candidate, self.plan)

    def test_modified_manager_or_host_bytes_are_refused(self):
        self.entries["NeAntik.app/Contents/MacOS/NeAntik"] = b"wrong-manager"
        self.write_archive()
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(MOD.PreflightError, "manager-sha-mismatch"):
            MOD.inspect(self.candidate, self.plan)

    def test_missing_or_mismatched_tls_scope_is_refused(self):
        self.host_info.pop("NeAntikQATrustScope")
        self.entries["NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/Info.plist"] = plistlib.dumps(self.host_info)
        self.write_archive()
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(MOD.PreflightError, "qa-tls-anchor-not-bound-to-host"):
            MOD.inspect(self.candidate, self.plan)

    def test_fixture_anchor_and_origin_must_match_signed_host_scope(self):
        anchor = self.fixture_root / "certificates/ca.der"
        anchor.write_bytes(b"different synthetic CA")
        with self.assertRaisesRegex(MOD.PreflightError, "qa-tls-fixture-anchor-mismatch"):
            MOD.inspect(self.candidate, self.plan)
        anchor.write_bytes(self.anchor)
        alternate = "https://different.neantik-dns.invalid:45102"
        self.candidate["qaTrustOrigin"] = self.plan["qaTrustOrigin"] = alternate
        with self.assertRaisesRegex(MOD.PreflightError, "qa-tls-fixture-origin-mismatch"):
            MOD.inspect(self.candidate, self.plan)

    def test_signed_host_must_keep_exact_ats_exception_and_dev_identity(self):
        host_path = "NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/Info.plist"
        self.host_info["NSAppTransportSecurity"]["NSExceptionDomains"].clear()
        self.entries[host_path] = plistlib.dumps(self.host_info)
        self.write_archive()
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(MOD.PreflightError, "qa-tls-ats-origin-not-bound-to-host"):
            MOD.inspect(self.candidate, self.plan)
        self.host_info["NSAppTransportSecurity"]["NSExceptionDomains"]["abc123.neantik-dns.invalid"] = {
            "NSExceptionAllowsInsecureHTTPLoads": True}
        self.host_info["CFBundleIdentifier"] = "app.neantik.desktop.webkit-host"
        self.entries[host_path] = plistlib.dumps(self.host_info)
        self.write_archive()
        self.candidate["sha256"] = self.plan["archiveSHA256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(MOD.PreflightError, "host-bundle-id-mismatch"):
            MOD.inspect(self.candidate, self.plan)


if __name__ == "__main__":
    unittest.main()
