import importlib.util
import importlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "package-webkit-host.py"
SPEC = importlib.util.spec_from_file_location("package_webkit_host", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
NOTICE_MODULE = importlib.import_module("webkit_runtime_notices")
TEST_IDENTITY = "A" * 40
TEST_IDENTITY_LINE = f'  1) {TEST_IDENTITY} "Developer ID Application: QA ({MODULE.TEAM_ID})"\n  1 valid identities found\n'


class PackageWebKitHostTests(unittest.TestCase):
    def test_only_private_production_diagnostic_host_omits_timestamp(self):
        self.assertEqual(MODULE.host_timestamp_args(False), ["--timestamp"])
        self.assertEqual(MODULE.host_timestamp_args(True), ["--timestamp=none"])

    def test_runtime_image_binding_resolves_notice_verifier_resource_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Contents/Frameworks"
            binding = (Path(temporary) / "Contents/Resources/NeAntikRuntimeEvidence"
                       / "NeAntikRuntimeImageBinding.json")
            binding.parent.mkdir(parents=True)
            binding.write_text("{}", encoding="utf-8")

            self.assertEqual(MODULE.runtime_image_binding_source(frameworks), binding)

    def setUp(self):
        binding_patch = patch.object(
            NOTICE_MODULE, "_validate_v135_runtime_binding_evidence", return_value={})
        binding_patch.start()
        self.addCleanup(binding_patch.stop)
        self.webgpu_fixture = bytes.fromhex("cffaedfe") + b"test WebGPU Mach-O"
        self.webgpu_digest = hashlib.sha256(self.webgpu_fixture).hexdigest()
        digest_patch = patch.object(
            NOTICE_MODULE, "WEBGPU_IMAGE_SHA256", self.webgpu_digest)
        digest_patch.start()
        self.addCleanup(digest_patch.stop)
        original_webgpu_image = NOTICE_MODULE._webgpu_image

        def test_webgpu_image(frameworks):
            image = frameworks / NOTICE_MODULE.WEBGPU_IMAGE_PATH
            image.parent.mkdir(parents=True, exist_ok=True)
            if not image.exists():
                image.write_bytes(self.webgpu_fixture)
            return original_webgpu_image(frameworks)

        image_patch = patch.object(NOTICE_MODULE, "_webgpu_image", side_effect=test_webgpu_image)
        image_patch.start()
        self.addCleanup(image_patch.stop)
        self.jsc_fixture = bytes.fromhex("cffaedfe") + b"test JavaScriptCore Mach-O"
        self.jsc_digest = hashlib.sha256(self.jsc_fixture).hexdigest()

        def test_jsc_image(frameworks, review):
            image = frameworks / "JavaScriptCore.framework/Versions/A/JavaScriptCore"
            image.parent.mkdir(parents=True, exist_ok=True)
            image.write_bytes(self.jsc_fixture)
            review["sourceBinding"]["runtimeImageSHA256"] = self.jsc_digest
            return image

        jsc_image_patch = patch.object(
            NOTICE_MODULE, "_jsc_headerless_bsd2_image", side_effect=test_jsc_image)
        jsc_image_patch.start()
        self.addCleanup(jsc_image_patch.stop)
        # This package-host fixture uses synthetic WebKit binaries. The exact
        # image/notice hash and Mach-O checks are exercised by the dedicated
        # runtime-notice suite against its own pinned fixture contract.
        swift_image_patch = patch.object(
            NOTICE_MODULE, "_verify_webkit_swift_runtime_images")
        swift_image_patch.start()
        self.addCleanup(swift_image_patch.stop)

    @staticmethod
    def make_networking_service(frameworks, executable_name="app.neantik.desktop.webkit.Networking.Development"):
        service = frameworks / MODULE.NETWORK_PROCESS_RELATIVE_PATH
        contents = service / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": MODULE.NETWORK_PROCESS_ID,
            "CFBundleExecutable": executable_name,
            "CFBundlePackageType": "XPC!",
        }))
        executable = contents / "MacOS" / executable_name
        executable.write_bytes(bytes.fromhex("cffaedfe") + b"network process fixture")
        executable.chmod(0o755)
        return service, executable

    def make_release_xpc_services(self, frameworks):
        services = {}
        for identifier in MODULE.RELEASE_XPC_ENTITLEMENTS:
            executable_name = identifier.rsplit(".", 1)[-1]
            if identifier == MODULE.NETWORK_PROCESS_ID:
                executable_name += ".Development"
            bundle = frameworks / "WebKit.framework/Versions/A/XPCServices" / f"{identifier}.xpc"
            contents = bundle / "Contents"
            executable = contents / "MacOS" / executable_name
            executable.parent.mkdir(parents=True, exist_ok=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": executable_name,
                "CFBundlePackageType": "XPC!",
            }))
            executable.write_bytes(bytes.fromhex("cffaedfe") + identifier.encode())
            executable.chmod(0o755)
            services[identifier] = bundle
        return services

    def test_development_qa_host_requires_compiled_tls_scope_support(self):
        with tempfile.TemporaryDirectory() as temporary:
            host = Path(temporary) / "NeAntikWebKitHost"
            host.write_bytes(bytes.fromhex("cffaedfe") + b"qa-tls-scope-installed "
                             b"NEANTIK_WEBKIT_PROXY_QUALIFICATION "
                             b"NEANTIK_WEBKIT_STARTUP_STAGE stage=")
            MODULE.verify_development_qa_host_binary(host)
            host.write_bytes(bytes.fromhex("cffaedfe") + b"production host without QA TLS")
            with self.assertRaisesRegex(MODULE.ContractError,
                                        "matching QA-only proxy flag"):
                MODULE.verify_development_qa_host_binary(host)

    @staticmethod
    def linked_host_outputs(load_path="@rpath/WebKit.framework/Versions/A/WebKit",
                            rpaths=("@executable_path/../Frameworks",)):
        linked = "/tmp/NeAntikWebKitHost:\n"
        linked += f"\t{load_path} (compatibility version 1.0.0, current version 625.1.24)\n"
        commands = "".join(
            f"          cmd LC_RPATH\n         path {value} (offset 12)\n"
            for value in rpaths
        )
        commands += "          cmd LC_BUILD_VERSION\n      platform 1\n         minos 15.4\n           sdk 15.4\n"
        return linked, commands

    def test_pin_is_versioned_and_binds_hashes_to_fixed_nested_identity(self):
        value = MODULE.pinned_info({"CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID},
                                   "a" * 64, "b" * 40)
        self.assertEqual(value[MODULE.PIN_KEY], {
            "schemaVersion": 1,
            "identifier": MODULE.HOST_BUNDLE_ID,
            "sha256": "a" * 64,
            "cdHash": "b" * 40,
        })
        self.assertNotIn("com.apple.security.cs.allow-dyld-environment-variables", value)

    def test_development_bundle_is_accepted_only_for_explicit_isolated_qa(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik-Dev.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.DEVELOPMENT_BUNDLE_ID,
                "CFBundleExecutable": "NeAntik",
            }))
            with self.assertRaisesRegex(MODULE.ContractError, "Unexpected manager bundle identity"):
                MODULE.read_info(app)
            info = MODULE.read_info(app, allow_development_qa=True)
            host_id = MODULE.DEVELOPMENT_BUNDLE_ID + ".webkit-host"
            pin = MODULE.pinned_info(info, "a" * 64, "b" * 40, host_id)
            self.assertEqual(pin[MODULE.PIN_KEY]["identifier"], host_id)

    def test_only_dev_host_gets_every_synthetic_http_ats_exception(self):
        dev_policy = MODULE.host_ats_policy(MODULE.DEVELOPMENT_BUNDLE_ID, True)
        self.assertEqual(dev_policy, {"NSAppTransportSecurity": {
            "NSExceptionDomains": {
                "127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True},
                "neantik-proxy-qa.invalid": {"NSExceptionAllowsInsecureHTTPLoads": True},
                "neantik-second-qa.invalid": {"NSExceptionAllowsInsecureHTTPLoads": True},
            },
        }})
        self.assertEqual(MODULE.host_ats_policy(MODULE.PRODUCTION_BUNDLE_ID, True), {})
        self.assertEqual(MODULE.host_ats_policy(MODULE.DEVELOPMENT_BUNDLE_ID, False), {})

    def test_qa_tls_ats_exception_is_exact_dev_only(self):
        origin = "https://0123456789abcdef0123456789abcdef.neantik-dns.invalid:45103"
        domains = MODULE.host_ats_policy(MODULE.DEVELOPMENT_BUNDLE_ID, True, [origin])[
            "NSAppTransportSecurity"]["NSExceptionDomains"]
        self.assertEqual(domains["0123456789abcdef0123456789abcdef.neantik-dns.invalid"],
                         {"NSExceptionAllowsInsecureHTTPLoads": True})
        self.assertNotIn("NSIncludesSubdomains", domains["0123456789abcdef0123456789abcdef.neantik-dns.invalid"])
        self.assertEqual(len(domains), len(MODULE.QA_HTTP_FIXTURE_ATS["NSExceptionDomains"]) + 1)
        self.assertEqual(MODULE.host_ats_policy(MODULE.PRODUCTION_BUNDLE_ID, True, [origin]), {})
        self.assertEqual(MODULE.host_ats_policy(MODULE.DEVELOPMENT_BUNDLE_ID, False, [origin]), {})
        diagnostic = MODULE.host_ats_policy(
            MODULE.PRODUCTION_BUNDLE_ID, False, [origin], allow_production_diagnostic=True)
        self.assertEqual(list(diagnostic["NSAppTransportSecurity"]["NSExceptionDomains"]),
                         ["0123456789abcdef0123456789abcdef.neantik-dns.invalid"])
        self.assertNotIn("0123456789abcdef0123456789abcdef.neantik-dns.invalid",
                         MODULE.QA_HTTP_FIXTURE_ATS["NSExceptionDomains"])
        for invalid in ("http://owned-tls.invalid:45103", "https://owned-tls.invalid:45103/path",
                        "https://example.com:45103", "https://owned-tls.invalid"):
            with self.subTest(invalid=invalid), self.assertRaises(MODULE.ContractError):
                MODULE.host_ats_policy(MODULE.DEVELOPMENT_BUNDLE_ID, True, [invalid])

    def test_qa_tls_anchor_is_exact_dev_only_signed_host_metadata(self):
        anchor = b"x" * 256
        origins = ["https://owned-tls.invalid:45103",
                   "https://other-owned-tls.invalid:45104"]
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            policy = MODULE.host_qa_tls_scope(MODULE.DEVELOPMENT_BUNDLE_ID, True,
                                               anchor, origins)
        self.assertEqual(policy[MODULE.QA_TLS_SCOPE_KEY],
                         {"anchorDER": anchor, "origins": origins})
        self.assertEqual(MODULE.host_qa_tls_scope(MODULE.PRODUCTION_BUNDLE_ID, False, None, []), {})
        with self.assertRaisesRegex(MODULE.ContractError, "Dev host"):
            MODULE.host_qa_tls_scope(MODULE.PRODUCTION_BUNDLE_ID, True, anchor, origins)
        with self.assertRaisesRegex(MODULE.ContractError, "Dev host"):
            MODULE.host_qa_tls_scope(MODULE.DEVELOPMENT_BUNDLE_ID, False, anchor, origins)

    def test_production_tls_scope_requires_explicit_diagnostic_lane(self):
        anchor = b"x" * 256
        origins = ["https://owned-tls.invalid:45103"]
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaisesRegex(MODULE.ContractError, "Dev host"):
                MODULE.host_qa_tls_scope(MODULE.PRODUCTION_BUNDLE_ID, False, anchor, origins)
            scope = MODULE.host_qa_tls_scope(
                MODULE.PRODUCTION_BUNDLE_ID, False, anchor, origins,
                allow_production_diagnostic=True)
        self.assertEqual(scope[MODULE.QA_TLS_SCOPE_KEY],
                         {"anchorDER": anchor, "origins": origins})

    def test_production_diagnostic_binary_requires_diagnostic_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            host = Path(temporary) / "host"
            host.write_bytes(b"NEANTIK_WEBKIT_PROXY_DIAGNOSTIC qa-tls-scope-installed "
                             b"NEANTIK_WEBKIT_STARTUP_STAGE stage=")
            MODULE.verify_development_qa_host_binary(host, production_diagnostic=True)
            with self.assertRaisesRegex(MODULE.ContractError, "matching QA-only"):
                MODULE.verify_development_qa_host_binary(host)

    def test_qa_tls_scope_rejects_broad_or_partial_inputs_before_staging(self):
        anchor = b"x" * 256
        with self.assertRaisesRegex(MODULE.ContractError, "anchor"):
            MODULE.host_qa_tls_scope(MODULE.DEVELOPMENT_BUNDLE_ID, True, None,
                                     ["https://owned-tls.invalid:45103"])
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(MODULE.ContractError, "X.509"):
                MODULE.host_qa_tls_scope(MODULE.DEVELOPMENT_BUNDLE_ID, True, anchor,
                                         ["https://owned-tls.invalid:45103"])
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            for origin in ("http://owned-tls.invalid:45103",
                           "https://owned-tls.invalid:45103/path",
                           "https://owned-tls.invalid:0",
                           "https://owned-tls.invalid:65536",
                           "https://bad..invalid:45103",
                           "https://not-fixture.example:45103"):
                with self.subTest(origin=origin), self.assertRaises(MODULE.ContractError):
                    MODULE.host_qa_tls_scope(MODULE.DEVELOPMENT_BUNDLE_ID, True, anchor, [origin])
            with self.assertRaisesRegex(MODULE.ContractError, "distinct"):
                MODULE.host_qa_tls_scope(MODULE.DEVELOPMENT_BUNDLE_ID, True, anchor,
                                         ["https://owned-tls.invalid:45103"] * 2)

    def test_pin_refuses_malformed_hashes(self):
        for sha, cdhash in (("A" * 64, "b" * 40), ("a" * 63, "b" * 40),
                            ("a" * 64, "b" * 39), ("a" * 64, "g" * 40)):
            with self.subTest(sha=sha, cdhash=cdhash):
                with self.assertRaises(MODULE.ContractError):
                    MODULE.pinned_info({}, sha, cdhash)

    def test_network_process_pin_requires_exact_nested_xpc_identity_and_team(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            service, executable = self.make_networking_service(frameworks)
            detail = (f"Identifier={MODULE.NETWORK_PROCESS_ID}\n"
                      f"TeamIdentifier={MODULE.TEAM_ID}\nCDHash=" + "d" * 40 + "\n")
            def signed_run(args, **kwargs):
                return subprocess.CompletedProcess(args, 0, "", detail)
            with patch.object(MODULE.subprocess, "run", side_effect=signed_run):
                pin = MODULE.network_process_pin(frameworks)
            self.assertEqual(pin, {
                "schemaVersion": 1,
                "identifier": MODULE.NETWORK_PROCESS_ID,
                "executable": "app.neantik.desktop.webkit.Networking.Development",
                "sha256": MODULE.digest(executable),
                "cdHash": "d" * 40,
            })

            info_path = service / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleIdentifier"] = "com.apple.WebKit.Networking"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(MODULE.ContractError, "expected owned service"):
                MODULE.network_process_pin(frameworks)

            info["CFBundleIdentifier"] = MODULE.NETWORK_PROCESS_ID
            info_path.write_bytes(plistlib.dumps(info))
            wrong_team = detail.replace(MODULE.TEAM_ID, "AAAAAAAAAA")
            with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", wrong_team)), \
                 self.assertRaisesRegex(MODULE.ContractError, "not signed by the expected Developer ID team"):
                MODULE.network_process_pin(frameworks)

    def test_network_process_pin_accepts_one_explicit_recipient_team(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            self.make_networking_service(frameworks)
            recipient_team = "B1C2D3E4F5"
            detail = (f"Identifier={MODULE.NETWORK_PROCESS_ID}\n"
                      f"TeamIdentifier={recipient_team}\nCDHash=" + "e" * 40 + "\n")
            def signed_run(args, **kwargs):
                return subprocess.CompletedProcess(args, 0, "", detail)
            with patch.object(MODULE.subprocess, "run", side_effect=signed_run):
                pin = MODULE.network_process_pin(frameworks, expected_team=recipient_team)
            self.assertEqual(pin["identifier"], MODULE.NETWORK_PROCESS_ID)
            self.assertEqual(pin["cdHash"], "e" * 40)
            with patch.object(MODULE.subprocess, "run", side_effect=signed_run), \
                 self.assertRaisesRegex(MODULE.ContractError, "expected Developer ID team"):
                MODULE.network_process_pin(frameworks, expected_team=MODULE.TEAM_ID)

    def test_cdhash_parser_requires_one_canonical_sha1_hash(self):
        self.assertEqual(MODULE.parse_cdhash("Identifier=x\nCDHash=" + "C" * 40 + "\n"), "c" * 40)
        for value in ("CDHash=short", "CDHash=" + "a" * 40 + "\nCDHash=" + "b" * 40):
            with self.subTest(value=value):
                with self.assertRaises(MODULE.ContractError):
                    MODULE.parse_cdhash(value)

    def test_host_linkage_selects_only_its_bundled_webkit(self):
        with tempfile.TemporaryDirectory() as temporary:
            host = Path(temporary) / "host"
            host.write_bytes(bytes.fromhex("cffaedfe") + b"runtime host")
            host.chmod(0o755)
            linked, commands = self.linked_host_outputs()

            def fake_run(args, **kwargs):
                return subprocess.CompletedProcess(
                    args, 0, linked if args[1] == "-L" else commands, "")

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                MODULE.verify_runtime_webkit_linkage(host)

            # Regression for QA197d: rebinding the direct framework is not
            # enough if the system Swift overlay loads system WebKit again.
            for dependency in ("/usr/lib/swift/libswiftWebKit.dylib",
                               "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI",
                               "/System/Library/Frameworks/WebCore.framework/Versions/A/WebCore"):
                mixed = linked + "\n\t" + dependency + " (compatibility version 1.0.0, current version 1.0.0)\n"
                def mixed_run(args, **kwargs):
                    return subprocess.CompletedProcess(args, 0, mixed if args[1] == "-L" else commands, "")
                with self.subTest(dependency=dependency), \
                     patch.object(MODULE.subprocess, "run", side_effect=mixed_run), \
                     self.assertRaises(MODULE.ContractError):
                    MODULE.verify_runtime_webkit_linkage(host)

            cases = (
                ("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
                 ("@executable_path/../Frameworks",)),
                ("@rpath/WebKit.framework/Versions/A/WebKit",
                 ("@executable_path/../Frameworks", "/System/Library/Frameworks")),
                ("@rpath/WebKit.framework/Versions/A/WebKit", ()),
            )
            for load_path, rpaths in cases:
                bad_link, bad_commands = self.linked_host_outputs(load_path, rpaths)

                def bad_run(args, **kwargs):
                    return subprocess.CompletedProcess(
                        args, 0, bad_link if args[1] == "-L" else bad_commands, "")

                with self.subTest(load_path=load_path, rpaths=rpaths), \
                     patch.object(MODULE.subprocess, "run", side_effect=bad_run), \
                     self.assertRaises(MODULE.ContractError):
                    MODULE.verify_runtime_webkit_linkage(host)

    def test_runtime_minimum_os_uses_every_image_and_normalizes_patch(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary)
            lower = frameworks / "WebKit"
            higher = frameworks / "XPC"
            lower.write_bytes(bytes.fromhex("cffaedfe") + b"lower")
            higher.write_bytes(bytes.fromhex("cffaedfe") + b"higher")
            def fake_run(args, **kwargs):
                version = "15.4" if args[-1] == str(lower) else "15.4.1"
                output = f"          cmd LC_BUILD_VERSION\n      platform 1\n         minos {version}\n           sdk 27.0\n"
                return subprocess.CompletedProcess(args, 0, output, "")
            with patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                self.assertEqual(MODULE.runtime_minimum_os_version(frameworks), "15.4.1")

            def macos_and_catalyst(args, **kwargs):
                self.assertEqual(args[2:4], ["-arch", "arm64"])
                output = ("          cmd LC_BUILD_VERSION\n      platform 1\n"
                          "         minos 15.4\n"
                          "          cmd LC_BUILD_VERSION\n      platform 6\n"
                          "         minos 18.0\n")
                return subprocess.CompletedProcess(args, 0, output, "")
            with patch.object(MODULE.subprocess, "run", side_effect=macos_and_catalyst):
                self.assertEqual(MODULE.runtime_minimum_os_version(frameworks), "15.4.0")

            def incompatible_platform(args, **kwargs):
                output = "          cmd LC_BUILD_VERSION\n      platform 6\n         minos 15.4\n           sdk 27.0\n"
                return subprocess.CompletedProcess(args, 0, output, "")
            with patch.object(MODULE.subprocess, "run", side_effect=incompatible_platform), \
                 self.assertRaisesRegex(MODULE.ContractError, "must target macOS"):
                MODULE.runtime_minimum_os_version(frameworks)

    def test_webkit_host_uses_no_custom_entitlements(self):
        self.assertEqual(MODULE.HOST_ENTITLEMENTS, {})

    def test_release_xpc_entitlement_gate_accepts_exact_distribution_set(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary)
            services = self.make_release_xpc_services(frameworks)

            def fake_run(args, **kwargs):
                bundle = Path(args[-1])
                identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
                return subprocess.CompletedProcess(
                    args, 0, plistlib.dumps(MODULE.RELEASE_XPC_ENTITLEMENTS[identifier]), b"")

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                MODULE.verify_release_xpc_entitlements(frameworks)

    @staticmethod
    def valid_xpc_entitlement_run(args, **kwargs):
        bundle = Path(args[-1])
        identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        return subprocess.CompletedProcess(
            args, 0, plistlib.dumps(MODULE.RELEASE_XPC_ENTITLEMENTS[identifier]), b"")

    def test_release_xpc_entitlement_gate_rejects_missing_or_unexpected_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary)
            services = self.make_release_xpc_services(frameworks)
            shutil.rmtree(services[MODULE.NETWORK_PROCESS_ID])
            with patch.object(MODULE.subprocess, "run", side_effect=self.valid_xpc_entitlement_run):
                with self.assertRaisesRegex(MODULE.ContractError, "Release runtime XPC set is incomplete"):
                    MODULE.verify_release_xpc_entitlements(frameworks)

        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary)
            services = self.make_release_xpc_services(frameworks)
            info_path = services[MODULE.NETWORK_PROCESS_ID] / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleIdentifier"] = "com.apple.WebKit.Networking"
            info_path.write_bytes(plistlib.dumps(info))
            with patch.object(MODULE.subprocess, "run", side_effect=self.valid_xpc_entitlement_run):
                with self.assertRaisesRegex(MODULE.ContractError, "Unexpected or duplicate"):
                    MODULE.verify_release_xpc_entitlements(frameworks)

    def test_release_xpc_entitlement_gate_rejects_invalid_or_debug_blob(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary)
            services = self.make_release_xpc_services(frameworks)
            target = services[MODULE.NETWORK_PROCESS_ID]

            def invalid_run(args, **kwargs):
                return subprocess.CompletedProcess(args, 0, b"", b"contains an invalid entitlements blob")

            with patch.object(MODULE.subprocess, "run", side_effect=invalid_run), \
                 self.assertRaisesRegex(MODULE.ContractError, "invalid or empty"):
                MODULE.verify_release_xpc_entitlements(frameworks)

            def debug_run(args, **kwargs):
                bundle = Path(args[-1])
                identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
                entitlements = dict(MODULE.RELEASE_XPC_ENTITLEMENTS[identifier])
                entitlements["com.apple.security.get-task-allow"] = True
                return subprocess.CompletedProcess(args, 0, plistlib.dumps(entitlements), b"")

            with patch.object(MODULE.subprocess, "run", side_effect=debug_run), \
                 self.assertRaisesRegex(MODULE.ContractError, "Debug entitlement is forbidden"):
                MODULE.verify_release_xpc_entitlements(frameworks)

    def test_packaging_pins_the_signed_nested_binary_before_outer_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            info = {"CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
                    "CFBundleShortVersionString": "0.8.25", "CFBundleVersion": "137"}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            resources = contents / "Resources"
            (resources / "NeAntikRuntimeCompliance").mkdir(parents=True)
            (resources / "NeAntikRuntimeNotices.md").write_text(
                "# NeAntik Chromium runtime notices\n", encoding="utf-8")
            (resources / "NeAntikRuntimeCompliance/THIRD-PARTY-NOTICES.html").write_text(
                "<!doctype html><html><body><h1>Chromium notices</h1></body></html>",
                encoding="utf-8")
            binary = root / "NeAntik"
            binary.write_bytes(bytes.fromhex("cffaedfe") + b"runtime-linked host fixture")
            binary.chmod(0o755)
            frameworks = root / "runtime/Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"signed WebKit fixture")
            # This integration-shaped packaging test includes the actual pinned
            # resource; dedicated notice tests check its bytes and negative cases.
            fixture = Path(os.environ.get("NEANTIK_TEST_RUNTIME_FRAMEWORKS", str(
                SCRIPT.parents[1] / "dist/private/candidates/ef2ce9cf159242c3a147027867403460/NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/Frameworks")))
            webcore_resources = Path("WebCore.framework/Versions/A/Resources")
            shutil.copytree(fixture / webcore_resources, frameworks / webcore_resources,
                            dirs_exist_ok=True)
            (frameworks / "libANGLE-shared.dylib").write_bytes(
                bytes.fromhex("cffaedfe") + b"signed ANGLE fixture")
            (frameworks / "libwebrtc.dylib").write_bytes(
                bytes.fromhex("cffaedfe") + b"signed WebRTC fixture")
            (frameworks / "libswiftCompatibilitySpan.dylib").write_bytes(
                bytes.fromhex("cffaedfe") + b"signed CompatibilitySpan fixture")
            for name in ("CSSDocumentation", "CodeMirror", "Esprima", "three.js"):
                source = (SCRIPT.parents[1] / "docs/evidence/third-party/webinspector" /
                          name / "LICENSE")
                resource = (frameworks / "WebInspectorUI.framework/Versions/A/Resources/External"
                            / name / "LICENSE")
                resource.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, resource)
            services = self.make_release_xpc_services(frameworks)
            networking_executable = (services[MODULE.NETWORK_PROCESS_ID] / "Contents/MacOS" /
                                     "Networking.Development")
            entitlement_bytes = plistlib.dumps({})
            detail = (f"Identifier={MODULE.HOST_BUNDLE_ID}\n"
                      f"TeamIdentifier={MODULE.TEAM_ID}\nTimestamp=Oct 21, 2026 at 00:00:00\nCDHash=" + "c" * 40 + "\n")
            linked, commands = self.linked_host_outputs()
            observed_commands = []

            def fake_run(args, **kwargs):
                observed_commands.append(args)
                if args[0] == "/usr/bin/security":
                    return subprocess.CompletedProcess(args, 0, TEST_IDENTITY_LINE, "")
                if args[0] == "/usr/bin/otool":
                    return subprocess.CompletedProcess(
                        args, 0, linked if args[1] == "-L" else commands, "")
                if args[1:4] == ["-d", "--entitlements", ":-"]:
                    bundle = Path(args[-1])
                    info_path = bundle / "Contents/Info.plist"
                    if info_path.is_file():
                        identifier = plistlib.loads(info_path.read_bytes()).get("CFBundleIdentifier")
                        if identifier in MODULE.RELEASE_XPC_ENTITLEMENTS:
                            return subprocess.CompletedProcess(
                                args, 0,
                                plistlib.dumps(MODULE.RELEASE_XPC_ENTITLEMENTS[identifier]), b"")
                    return subprocess.CompletedProcess(args, 0, entitlement_bytes, b"")
                if args[1:3] == ["-dv", "--verbose=4"]:
                    if str(MODULE.NETWORK_PROCESS_RELATIVE_PATH.name) in args[-1]:
                        network_detail = (f"Identifier={MODULE.NETWORK_PROCESS_ID}\n"
                                          f"TeamIdentifier={MODULE.TEAM_ID}\nTimestamp=Oct 21, 2026 at 00:00:00\nCDHash=" + "d" * 40 + "\n")
                        return subprocess.CompletedProcess(args, 0, "", network_detail)
                    return subprocess.CompletedProcess(args, 0, "", detail)
                return subprocess.CompletedProcess(args, 0, b"", b"")

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                # The runtime must already be Developer ID signed before it
                # can be sealed into the separately signed host bundle.
                runtime_detail = detail.replace("TeamIdentifier=not set", f"TeamIdentifier={MODULE.TEAM_ID}")
                def signed_runtime_run(args, **kwargs):
                    result = fake_run(args, **kwargs)
                    if args[0] == "/usr/bin/codesign" and args[1:3] == ["-dv", "--verbose=4"] and str(webkit) in args:
                        return subprocess.CompletedProcess(args, 0, "", runtime_detail)
                    return result
                with patch.object(MODULE.subprocess, "run", side_effect=signed_runtime_run):
                    host_bundle = MODULE.package(app, binary, frameworks, TEST_IDENTITY)

            host_sign_calls = [args for args in observed_commands
                               if args[:3] == ["/usr/bin/codesign", "--force", "--options"]]
            self.assertEqual(len(host_sign_calls), 1)
            self.assertNotIn("--entitlements", host_sign_calls[0])

            self.assertEqual(host_bundle, app / MODULE.HOST_BUNDLE_RELATIVE_PATH)
            host = app / MODULE.HOST_EXECUTABLE_RELATIVE_PATH
            self.assertEqual(host.read_bytes(), binary.read_bytes())
            host_info = plistlib.loads((host_bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(host_info["CFBundleIdentifier"], MODULE.HOST_BUNDLE_ID)
            self.assertEqual(host_info["CFBundleExecutable"], "NeAntikWebKitHost")
            self.assertEqual(host_info["CFBundlePackageType"], "APPL")
            self.assertEqual(host_info[MODULE.RUNTIME_PIN_KEY], {
                "schemaVersion": 2,
                "webKitSHA256": MODULE.digest(webkit),
                "minimumOSVersion": "15.4.0",
            })
            self.assertEqual((host_bundle / "Contents/Frameworks/WebKit.framework/Versions/A/WebKit").read_bytes(),
                             webkit.read_bytes())
            sealed = plistlib.loads((contents / "Info.plist").read_bytes())
            self.assertEqual(sealed[MODULE.PIN_KEY], {
                "schemaVersion": 1,
                "identifier": MODULE.HOST_BUNDLE_ID,
                "sha256": MODULE.digest(host),
                "cdHash": "c" * 40,
            })
            self.assertEqual(sealed[MODULE.NETWORK_PROCESS_PIN_KEY], {
                "schemaVersion": 1,
                "identifier": MODULE.NETWORK_PROCESS_ID,
                "executable": "Networking.Development",
                "sha256": MODULE.digest(networking_executable),
                "cdHash": "d" * 40,
            })
            self.assertEqual(
                (resources / "NeAntikRuntimeLicenses" /
                 "Swift-6.4.0-Runtime-Library-Exception-LICENSE.txt").read_bytes(),
                (SCRIPT.parents[1] / "runtime/licenses/Swift-6.4.0-Runtime-Library-Exception-LICENSE.txt").read_bytes(),
            )
            self.assertEqual(
                (resources / "NeAntikRuntimeLicenses" / "WebCore-LICENSE-LGPL-2.txt").read_bytes(),
                (SCRIPT.parents[1] / "docs/evidence/third-party/webcore/LICENSE-LGPL-2").read_bytes(),
            )
            self.assertEqual(
                (resources / "NeAntikRuntimeLicenses" / "WebCore-LICENSE-LGPL-2.1.txt").read_bytes(),
                (SCRIPT.parents[1] / "docs/evidence/third-party/webcore/LICENSE-LGPL-2.1").read_bytes(),
            )
            self.assertIn(
                "WebKit source-referenced license text: LGPL-2",
                (resources / "NeAntikRuntimeNotices.md").read_text(encoding="utf-8"),
            )
            self.assertIn(
                "WebKit source-referenced license text: LGPL-2.1",
                (resources / "NeAntikRuntimeNotices.md").read_text(encoding="utf-8"),
            )
            angle_notice = (resources / "NeAntikRuntimeNotices.md").read_text(encoding="utf-8")
            self.assertIn("Source-mapped WebKit runtime notices: ANGLE", angle_notice)
            self.assertIn("ANGLE zlib compression helper symbols", angle_notice)
            self.assertIn("Bundled WebInspectorUI external license resources", angle_notice)
            for name, source in (
                ("ANGLE-LICENSE.txt", "docs/evidence/third-party/angle/ANGLE-LICENSE-43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"),
                ("xxHash-LICENSE.txt", "docs/evidence/third-party/angle/xxhash-LICENSE-e4c5da7234eca7baad9a46f0b144e49ccad2e500"),
                ("Chromium-ANGLE-DEPS-LICENSE.txt", "docs/evidence/third-party/chromium/LICENSE-738956cca47a264e92106fdbefdc040ee7ed487d"),
            ):
                self.assertEqual(
                    (resources / "NeAntikRuntimeLicenses" / name).read_bytes(),
                    (SCRIPT.parents[1] / source).read_bytes(),
                )
            webrtc_root = resources / "NeAntikRuntimeLicenses/WebRTC"
            webrtc_manifest = json.loads(
                (webrtc_root / "MANIFEST.json").read_text(encoding="utf-8"))
            self.assertEqual(webrtc_manifest["noticeFileCount"], 63)
            self.assertEqual(webrtc_manifest["noticeFileCount"], len(webrtc_manifest["notices"]))
            self.assertTrue((resources / "NeAntikRuntimeNotices.md").read_text(
                encoding="utf-8").count("Source-derived WebRTC notices") == 1)
            for notice in webrtc_manifest["notices"]:
                self.assertEqual(
                    (webrtc_root / notice["path"]).read_bytes(),
                    (SCRIPT.parents[1] / NOTICE_MODULE.WEBRTC_CANDIDATE_ROOT /
                     notice["path"]).read_bytes(),
                )

    def test_adhoc_host_identity_is_refused_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
            }))
            with self.assertRaisesRegex(MODULE.ContractError, "ad-hoc signing cannot load"):
                MODULE.package(app, root / "not-needed", root / "not-needed-frameworks", "-")
            self.assertFalse((app / MODULE.HOST_BUNDLE_RELATIVE_PATH).exists())
            self.assertFalse((contents / "Helpers").exists())

    def test_old_manager_copy_approach_is_refused_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
            }))
            manager = root / "NeAntik"
            manager.write_bytes(bytes.fromhex("cffaedfe") + b"manager")
            manager.chmod(0o755)
            linked, commands = self.linked_host_outputs(
                "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit")

            def fake_run(args, **kwargs):
                if args[0] == "/usr/bin/security":
                    return subprocess.CompletedProcess(args, 0, TEST_IDENTITY_LINE, "")
                return subprocess.CompletedProcess(
                    args, 0, linked if args[1] == "-L" else commands, "")

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run), \
                 self.assertRaises(MODULE.ContractError):
                MODULE.package(app, manager, root / "missing-frameworks", TEST_IDENTITY)
            self.assertFalse((app / MODULE.HOST_BUNDLE_RELATIVE_PATH).exists())

    def test_exact_manager_copy_is_rebound_in_temp_to_private_webkit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            executable = contents / "MacOS/NeAntik"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex("cffaedfe") + b"signed manager fixture")
            executable.chmod(0o755)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
                "CFBundleExecutable": "NeAntik",
            }))
            destination = root / "temporary/NeAntikWebKitHost"
            install_commands = []

            def fake_run(args, **kwargs):
                if args[0] == "/usr/bin/install_name_tool":
                    install_commands.append(args)
                    return subprocess.CompletedProcess(args, 0, "", "")
                if args[0] == "/usr/bin/otool" and args[1] == "-L":
                    load = (MODULE.SYSTEM_WEBKIT_LOAD if Path(args[-1]) == executable
                            else MODULE.OWNED_WEBKIT_LOAD)
                    linked, _ = self.linked_host_outputs(load)
                    return subprocess.CompletedProcess(args, 0, linked, "")
                if args[0] == "/usr/bin/otool" and args[1] == "-l":
                    _, commands = self.linked_host_outputs(rpaths=(
                        "/usr/lib/swift", "@loader_path", MODULE.OWNED_WEBKIT_RPATH))
                    return subprocess.CompletedProcess(args, 0, commands, "")
                raise AssertionError(args)

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                MODULE.derive_owned_webkit_host(app, executable, destination)

            self.assertEqual(executable.read_bytes(),
                             bytes.fromhex("cffaedfe") + b"signed manager fixture")
            self.assertEqual(destination.read_bytes(), executable.read_bytes())
            self.assertEqual(install_commands, [
                ["/usr/bin/install_name_tool", "-change", MODULE.SYSTEM_WEBKIT_LOAD,
                 MODULE.OWNED_WEBKIT_LOAD, str(destination)],
                ["/usr/bin/install_name_tool", "-add_rpath", MODULE.OWNED_WEBKIT_RPATH,
                 str(destination)],
            ])

    def test_swiftui_manager_is_refused_before_host_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            executable = app / "Contents/MacOS/NeAntik"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex("cffaedfe") + b"manager")
            executable.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
                "CFBundleExecutable": "NeAntik",
            }))
            destination = root / "derived/Host"
            linked, _ = self.linked_host_outputs(MODULE.SYSTEM_WEBKIT_LOAD)
            linked += ("\t/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI "
                       "(compatibility version 1.0.0, current version 1.0.0)\n")
            with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], 0, linked, "")), self.assertRaisesRegex(
                        MODULE.ContractError, "SwiftUI manager cannot be rebound"):
                MODULE.derive_owned_webkit_host(app, executable, destination)
            self.assertFalse(destination.exists())

    def test_rebind_refuses_symlinked_manager_executable_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            outside = root / "outside"
            outside.mkdir()
            executable = outside / "NeAntik"
            executable.write_bytes(bytes.fromhex("cffaedfe") + b"outside manager")
            executable.chmod(0o755)
            (contents / "MacOS").symlink_to(outside, target_is_directory=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
                "CFBundleExecutable": "NeAntik",
            }))
            destination = root / "temporary/NeAntikWebKitHost"

            with self.assertRaisesRegex(MODULE.ContractError, "directory must be physical"):
                MODULE.derive_owned_webkit_host(app, contents / "MacOS/NeAntik", destination)

            self.assertFalse(destination.exists())

    def test_rebind_refuses_wrong_source_and_non_system_webkit_load(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            executable = contents / "MacOS/NeAntik"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex("cffaedfe") + b"manager")
            executable.chmod(0o755)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
                "CFBundleExecutable": "NeAntik",
            }))
            other = root / "other/NeAntik"
            other.parent.mkdir()
            other.write_bytes(executable.read_bytes())
            other.chmod(0o755)
            with self.assertRaisesRegex(MODULE.ContractError, "exact executable"):
                MODULE.derive_owned_webkit_host(app, other, root / "out/Host")

            linked, _ = self.linked_host_outputs("@rpath/Other.framework/Versions/A/Other")
            with patch.object(MODULE.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, linked, "")), \
                 self.assertRaisesRegex(MODULE.ContractError, "exactly one system WebKit"):
                MODULE.derive_owned_webkit_host(app, executable, root / "out/Host")

    def test_packaging_refuses_symlinked_helper_parent_without_writing_through_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
            }))
            outside = root / "outside"
            outside.mkdir()
            (contents / "Helpers").symlink_to(outside, target_is_directory=True)
            binary = root / "NeAntik"
            binary.write_bytes(bytes.fromhex("cffaedfe") + b"owned manager fixture")
            binary.chmod(0o755)
            frameworks = root / "runtime/Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"signed WebKit fixture")
            linked, commands = self.linked_host_outputs()

            def fake_run(args, **kwargs):
                if args[0] == "/usr/bin/security":
                    return subprocess.CompletedProcess(args, 0, TEST_IDENTITY_LINE, "")
                if args[0] == "/usr/bin/codesign" and args[1:3] == ["-dv", "--verbose=4"]:
                    output = (f"Identifier={MODULE.HOST_BUNDLE_ID}\nTeamIdentifier={MODULE.TEAM_ID}\nCDHash="
                              + "c" * 40 + "\n")
                    return subprocess.CompletedProcess(args, 0, "", output)
                return subprocess.CompletedProcess(
                    args, 0, linked if args[1] == "-L" else commands, "")

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run), \
                 self.assertRaises(MODULE.ContractError):
                MODULE.package(app, binary, frameworks, TEST_IDENTITY)
            self.assertEqual(list(outside.iterdir()), [])

    def test_missing_selected_identity_fails_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
            }))
            with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess(
                    ["security", "find-identity"], 0, "  0 valid identities found\n", "")):
                with self.assertRaisesRegex(MODULE.ContractError, "identity is unavailable"):
                    MODULE.package(app, root / "not-needed", root / "not-needed-frameworks", TEST_IDENTITY)
            self.assertFalse((contents / "Helpers").exists())

    def test_foreign_team_identity_fails_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
            }))
            foreign = f'  1) {TEST_IDENTITY} "Developer ID Application: QA (OTHERTEAM1)"\n'
            with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess(
                    ["security", "find-identity"], 0, foreign, "")):
                with self.assertRaisesRegex(MODULE.ContractError, "does not match the expected manager team"):
                    MODULE.package(app, root / "not-needed", root / "not-needed-frameworks", TEST_IDENTITY)
            self.assertFalse((contents / "Helpers").exists())

    def test_recipient_identity_is_accepted_only_when_explicit_expected_team_matches(self):
        recipient_team = "B1C2D3E4F5"
        line = f'  1) {TEST_IDENTITY} "Developer ID Application: QA ({recipient_team})"\n'
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess(
                ["security", "find-identity"], 0, line, "")):
            MODULE.verify_signing_identity(TEST_IDENTITY, expected_team=recipient_team)
            with self.assertRaisesRegex(MODULE.ContractError, "does not match the expected manager team"):
                MODULE.verify_signing_identity(TEST_IDENTITY)

    def test_recipient_manager_team_requires_strict_matching_identifier_and_developer_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            executable = app / "Contents/MacOS/NeAntik"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"signed manager fixture")
            good = f"Identifier={MODULE.PRODUCTION_BUNDLE_ID}\nTeamIdentifier=B1C2D3E4F5\n"
            def signed_run(args, **kwargs):
                return subprocess.CompletedProcess(args, 0, "", good)
            with patch.object(MODULE.subprocess, "run", side_effect=signed_run):
                self.assertEqual(MODULE.manager_signing_team(app, MODULE.PRODUCTION_BUNDLE_ID), "B1C2D3E4F5")
            wrong = good.replace(MODULE.PRODUCTION_BUNDLE_ID, "other.identifier")
            with patch.object(MODULE.subprocess, "run", side_effect=lambda args, **kwargs:
                              subprocess.CompletedProcess(args, 0, "", wrong)), \
                 self.assertRaisesRegex(MODULE.ContractError, "not a valid Developer ID team"):
                MODULE.manager_signing_team(app, MODULE.PRODUCTION_BUNDLE_ID)

    def test_recipient_manager_signature_failure_names_the_failed_stage_without_stderr(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            executable = app / "Contents/MacOS/NeAntik"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"manager fixture")
            for failing_call, stage in ((1, "bundle signature"), (2, "executable signature")):
                calls = 0
                def run(args, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == failing_call:
                        raise subprocess.CalledProcessError(1, args, stderr=b"private path or identity")
                    return subprocess.CompletedProcess(args, 0, "", "")
                with patch.object(MODULE.subprocess, "run", side_effect=run), \
                     self.assertRaisesRegex(MODULE.ContractError, stage) as failure:
                    MODULE.manager_signing_team(app, MODULE.PRODUCTION_BUNDLE_ID)
                self.assertNotIn("private path or identity", str(failure.exception))

    def test_recipient_relink_option_propagates_manager_team_without_changing_release_default(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "NeAntik.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID,
                "CFBundleExecutable": "NeAntik",
            }))
            manager = contents / "MacOS/NeAntik"
            manager.write_bytes(bytes.fromhex("cffaedfe") + b"manager")
            manager.chmod(0o755)
            external_host = root / "host"
            external_host.write_bytes(bytes.fromhex("cffaedfe") + b"host")
            external_host.chmod(0o755)
            recipient_team = "B1C2D3E4F5"
            with patch.object(MODULE, "manager_signing_team", return_value=recipient_team), \
                 patch.object(MODULE, "verify_signing_identity") as verify_identity, \
                 patch.object(MODULE, "_package_verified_host", return_value=root / "host.app") as pack:
                result = MODULE.package(app, external_host, root / "Frameworks", TEST_IDENTITY,
                                        recipient_relink=True)
            self.assertEqual(result, root / "host.app")
            verify_identity.assert_called_once_with(TEST_IDENTITY, recipient_team)
            self.assertEqual(pack.call_args.kwargs["expected_team"], recipient_team)

            with patch.object(MODULE, "verify_signing_identity") as verify_default, \
                 patch.object(MODULE, "_package_verified_host", return_value=root / "release-host.app"):
                MODULE.package(app, external_host, root / "Frameworks", TEST_IDENTITY)
            verify_default.assert_called_once_with(TEST_IDENTITY)

    def test_unsigned_or_foreign_framework_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frameworks = root / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"untrusted")
            bad_signature = subprocess.CalledProcessError(1, ["codesign"])
            with patch.object(MODULE.subprocess, "run", side_effect=bad_signature), \
                 self.assertRaises(MODULE.ContractError):
                MODULE.verify_runtime_frameworks(frameworks)

    def test_nested_runtime_image_requires_same_neantik_team(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Frameworks"
            webkit = root / "WebKit.framework/Versions/A/WebKit"
            nested = root / "JavaScriptCore.framework/Versions/A/JavaScriptCore"
            webkit.parent.mkdir(parents=True)
            nested.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"signed WebKit fixture")
            nested.write_bytes(bytes.fromhex("cffaedfe") + b"foreign nested image")

            def fake_run(args, **kwargs):
                if args[:3] == ["/usr/bin/codesign", "-dv", "--verbose=4"]:
                    team = MODULE.TEAM_ID if str(webkit) in args else "OTHERTEAM1"
                    detail = f"TeamIdentifier={team}\nTimestamp=Oct 21, 2026 at 00:00:00\n"
                    return subprocess.CompletedProcess(args, 0, "", detail)
                return subprocess.CompletedProcess(args, 0, b"", b"")

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run), \
                 self.assertRaisesRegex(
                     MODULE.ContractError,
                     r"Runtime Mach-O image JavaScriptCore\.framework/Versions/A/JavaScriptCore must use",
                 ):
                MODULE.verify_runtime_frameworks(root)

    def test_nested_runtime_image_requires_secure_timestamp(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Frameworks"
            webkit = root / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"signed WebKit fixture")

            def fake_run(args, **kwargs):
                if args[:3] == ["/usr/bin/codesign", "-dv", "--verbose=4"]:
                    # A valid same-team signature without a secure timestamp
                    # was accepted by local codesign but rejected by Apple.
                    return subprocess.CompletedProcess(
                        args, 0, "", f"TeamIdentifier={MODULE.TEAM_ID}\n")
                return subprocess.CompletedProcess(args, 0, b"", b"")

            with patch.object(MODULE.subprocess, "run", side_effect=fake_run), \
                 self.assertRaisesRegex(MODULE.ContractError, "secure code-signing timestamp"):
                MODULE.verify_runtime_frameworks(root)

    def test_nested_runtime_images_accept_recipient_team_but_reject_mixed_team(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Frameworks"
            webkit = root / "WebKit.framework/Versions/A/WebKit"
            nested = root / "JavaScriptCore.framework/Versions/A/JavaScriptCore"
            webkit.parent.mkdir(parents=True)
            nested.parent.mkdir(parents=True)
            for binary in (webkit, nested):
                binary.write_bytes(bytes.fromhex("cffaedfe") + b"signed fixture")
            recipient_team = "B1C2D3E4F5"

            def fake_run(args, **kwargs):
                if args[:3] == ["/usr/bin/codesign", "-dv", "--verbose=4"]:
                    detail = f"TeamIdentifier={recipient_team}\nTimestamp=Oct 21, 2026 at 00:00:00\n"
                    if str(nested) in args:
                        detail = f"TeamIdentifier={MODULE.TEAM_ID}\nTimestamp=Oct 21, 2026 at 00:00:00\n"
                    return subprocess.CompletedProcess(args, 0, "", detail)
                return subprocess.CompletedProcess(args, 0, b"", b"")

            # Static dependency and rpath passes are orthogonal to team binding.
            with patch.object(MODULE.subprocess, "run", side_effect=fake_run), \
                 patch.object(MODULE, "verify_no_system_engine_fallbacks"), \
                 patch.object(MODULE, "verify_relocatable_runtime_rpaths"):
                with self.assertRaisesRegex(MODULE.ContractError, "expected Developer ID team"):
                    MODULE.verify_runtime_frameworks(root, expected_team=recipient_team)

    def test_untrusted_signing_chain_is_not_misreported_as_invalid_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"runtime")
            failure = subprocess.CalledProcessError(
                1, ["codesign"], stderr=b"CSSMERR_TP_NOT_TRUSTED")
            with patch.object(MODULE.subprocess, "run", side_effect=failure), \
                 self.assertRaisesRegex(MODULE.ContractError, "signature chain is not trusted"):
                MODULE.verify_runtime_frameworks(frameworks)

    def test_signature_seal_failure_is_reported_separately_from_trust(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"runtime")
            failure = subprocess.CalledProcessError(
                1, ["codesign"], stderr=b"a sealed resource is missing or invalid")
            with patch.object(MODULE.subprocess, "run", side_effect=failure), \
                 self.assertRaisesRegex(MODULE.ContractError, "signature seal does not match"):
                MODULE.verify_runtime_frameworks(frameworks)

    def test_signature_seal_failure_takes_precedence_over_trust_warning(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"runtime")
            failure = subprocess.CalledProcessError(
                1, ["codesign"],
                stderr=b"CSSMERR_TP_NOT_TRUSTED; a sealed resource is missing or invalid")
            with patch.object(MODULE.subprocess, "run", side_effect=failure), \
                 self.assertRaisesRegex(MODULE.ContractError, "signature seal does not match"):
                MODULE.verify_runtime_frameworks(frameworks)

    def test_framework_payload_symlink_cannot_escape_source_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frameworks = root / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"runtime")
            outside = root / "outside"
            outside.write_text("not part of the signed runtime")
            (frameworks / "escape").symlink_to(outside)
            with self.assertRaises(MODULE.ContractError):
                MODULE.verify_runtime_frameworks(frameworks)

    def test_embedded_frameworks_reject_direct_absolute_system_engine_loads(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webcore = frameworks / "WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore"
            webcore.parent.mkdir(parents=True)
            webkit.parent.mkdir(parents=True, exist_ok=True)
            for binary in (webkit, webcore):
                binary.write_bytes(bytes.fromhex("cffaedfe") + b"runtime fixture")

            def run(args, **kwargs):
                binary = Path(args[-1])
                dependency = "@rpath/WebKit.framework/Versions/A/WebKit"
                if binary == webcore:
                    dependency = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore"
                output = f"{binary}:\n\t{dependency} (compatibility version 1.0.0, current version 1.0.0)\n"
                return subprocess.CompletedProcess(args, 0, output, "")

            with patch.object(MODULE.subprocess, "run", side_effect=run), \
                 self.assertRaisesRegex(MODULE.ContractError, "system WebKit engine"):
                MODULE.verify_no_system_engine_fallbacks(frameworks)

    def test_embedded_frameworks_allow_bundled_engine_load_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"runtime fixture")

            def run(args, **kwargs):
                output = f"{args[-1]}:\n\t@rpath/WebKit.framework/Versions/A/WebKit (compatibility version 1.0.0, current version 1.0.0)\n"
                return subprocess.CompletedProcess(args, 0, output, "")

            with patch.object(MODULE.subprocess, "run", side_effect=run):
                MODULE.verify_no_system_engine_fallbacks(frameworks)

    def test_embedded_frameworks_reject_weak_writing_tools_ui_load(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            swift = frameworks / "libWebKitSwift.dylib"
            frameworks.mkdir()
            swift.write_bytes(bytes.fromhex("cffaedfe") + b"runtime fixture")

            def run(args, **kwargs):
                output = (f"{args[-1]}:\n"
                          "\t/System/Library/PrivateFrameworks/WritingToolsUI.framework/"
                          "Versions/A/WritingToolsUI (compatibility version 1.0.0, "
                          "current version 1.0.0, weak)\n")
                return subprocess.CompletedProcess(args, 0, output, "")

            with patch.object(MODULE.subprocess, "run", side_effect=run), \
                 self.assertRaisesRegex(MODULE.ContractError, "WritingToolsUI"):
                MODULE.verify_no_system_engine_fallbacks(frameworks)

    def test_runtime_rpaths_allow_bundle_relative_and_system_swift_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"runtime fixture")
            commands = (
                "          cmd LC_RPATH\n         path @loader_path/../../../ (offset 12)\n"
                "          cmd LC_RPATH\n         path /usr/lib/swift (offset 12)\n"
            )

            def run(args, **kwargs):
                return subprocess.CompletedProcess(args, 0, commands, "")

            with patch.object(MODULE.subprocess, "run", side_effect=run):
                MODULE.verify_relocatable_runtime_rpaths(frameworks)

    def test_runtime_rpaths_reject_xcode_and_build_directory_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            frameworks = Path(temporary) / "Frameworks"
            webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
            webkit.parent.mkdir(parents=True)
            webkit.write_bytes(bytes.fromhex("cffaedfe") + b"runtime fixture")
            for rpath in (
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
                "/private/tmp/neantik-webkit-build/Release",
            ):
                commands = f"          cmd LC_RPATH\n         path {rpath} (offset 12)\n"

                def run(args, **kwargs):
                    return subprocess.CompletedProcess(args, 0, commands, "")

                with self.subTest(rpath=rpath), \
                     patch.object(MODULE.subprocess, "run", side_effect=run), \
                     self.assertRaisesRegex(MODULE.ContractError, "absolute non-system rpath"):
                    MODULE.verify_relocatable_runtime_rpaths(frameworks)


if __name__ == "__main__":
    unittest.main()
