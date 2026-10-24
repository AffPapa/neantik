from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import os
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "stage-webkit-runtime.py"
SPEC = importlib.util.spec_from_file_location("stage_webkit_runtime", SCRIPT)
stage = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(stage)


MACHO = bytes.fromhex("cffaedfe") + b"fixture"


class StageWebKitRuntimeTests(unittest.TestCase):
    def test_release_manifest_excludes_development_web_content_xpc(self):
        manifest = stage.load_manifest(
            SCRIPT.parents[1] / "runtime/webkit-production-staging-v4.json"
        )
        excluded = set(manifest["excludedPathComponents"])
        self.assertTrue(stage.omitted(
            Path("WebKit.framework/Versions/A/XPCServices/"
                 "app.neantik.desktop.webkit.WebContent.Development.xpc"),
            excluded,
        ))
        self.assertFalse(stage.omitted(
            Path("WebKit.framework/Versions/A/XPCServices/"
                 "app.neantik.desktop.webkit.WebContent.xpc"),
            excluded,
        ))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "build"
        self.root.mkdir()
        framework = self.root / "WebKit.framework/Versions/A"
        (framework / "Frameworks").mkdir(parents=True)
        (framework / "WebKit").write_bytes(MACHO)
        (self.root / "libWebKitSwift.dylib").write_bytes(MACHO)
        (framework / "Frameworks/libWebKitSwift.dylib").symlink_to("../../../../libWebKitSwift.dylib")
        (framework / "Resources").mkdir()
        (framework / "Resources/Localizable.strings").write_text("ok")
        self.policy = framework / "Resources/com.apple.WebKit.NetworkProcess.sb"
        self.policy.write_text(
            '(version 1)\n(deny default)\n(allow file-read*)\n'
            '(system-network)\n'
            '(with-filter (require-not (state-flag "BlockNetworkAccess"))\n'
            '    (allow network-outbound\n'
            '        (literal "/private/var/run/mDNSResponder")\n'
            '        (remote tcp)))\n'
            '(allow network-outbound\n    (remote udp))\n'
            '(with-filter (require-not (state-flag "BlockNetworkAccess"))\n'
            '    (allow network*\n'
            '        (local udp)\n'
            '        (remote udp)\n'
            '        (local tcp)\n'
            '        (remote tcp)))\n'
            '(allow mach-lookup\n'
            '    (global-name "com.apple.networkserviceproxy.fetch-token"))\n'
            '(allow mach-lookup (global-name "com.apple.webkit.adattributiond.service"))\n'
            '(allow mach-lookup (global-name "org.webkit.pcmtestdaemon.service"))\n'
            '(allow mach-lookup (global-name "com.apple.webkit.webpushd.service"))\n'
            '(allow mach-lookup (global-name "com.apple.webkit.webpushd.relocatable.service"))\n'
            '(allow mach-lookup (global-name "org.webkit.webpushtestdaemon.service"))\n'
            '(allow mach-lookup\n'
            '    (global-name "com.apple.cfnetwork.AuthBrokerAgent")\n'
            '    (global-name "com.apple.cfnetwork.cfnetworkagent")\n'
            '    (global-name "com.apple.nesessionmanager.flow-divert-token")\n'
            '    (global-name "com.apple.nesessionmanager.content-filter")\n'
            '    (global-name "com.apple.mobileasset.autoasset")\n'
            '    (global-name "com.apple.webprivacyd")\n'
            '    (global-name "com.apple.logd")\n'
            '    (global-name "com.apple.WebPrivacy.Service"))\n'
            '(deny syscall-unix)\n'
            '(allow syscall-unix (syscall-number SYS_socketpair))\n'
        )
        service = framework / "XPCServices/Test.xpc/Contents"
        (service / "MacOS").mkdir(parents=True)
        (service / "Info.plist").write_text("plist")
        (service / "MacOS/Test").write_bytes(MACHO)
        (framework / "Headers").mkdir()
        (framework / "Headers/NotForRuntime.h").write_text("header")
        (framework / "_CodeSignature").mkdir()
        (framework / "_CodeSignature/CodeResources").write_text("adhoc")
        (self.root / "WebKit.framework/Headers").symlink_to("Versions/A/Headers")
        (self.root / "WebKit.framework/Versions/Current").symlink_to("A")
        self.manifest = {
            "schemaVersion": 2,
            "upstream": {"repository": "WebKit/WebKit", "commit": "a" * 40},
            "runtimeItems": ["WebKit.framework", "libWebKitSwift.dylib"],
            "excludedPathComponents": ["Headers", "PrivateHeaders", "Modules", "_CodeSignature", "dSYMs"],
            "networkSandbox": {
                "path": "WebKit.framework/Versions/A/Resources/com.apple.WebKit.NetworkProcess.sb",
                "baseSHA256": hashlib.sha256(self.policy.read_bytes()).hexdigest(),
                "relayPort": 45100,
                "policyRevision": 13,
            },
            "stagingOnly": True,
            "signingRequiredAfterStaging": True,
        }

    def test_stages_runtime_resources_and_internal_links_without_dev_headers(self):
        destination = Path(self.temp.name) / "Frameworks"
        result = stage.copy_runtime(self.root, destination, self.manifest)
        self.assertEqual(result["status"], "staged-pre-sign-only")
        self.assertEqual(result["upstreamCommit"], "a" * 40)
        self.assertEqual(result["machOCount"], 4)
        self.assertTrue((destination / "WebKit.framework/Versions/A/Resources/Localizable.strings").is_file())
        self.assertTrue((destination / "WebKit.framework/Versions/A/XPCServices/Test.xpc/Contents/MacOS/Test").is_file())
        embedded_swift = destination / "WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib"
        self.assertTrue(embedded_swift.is_file())
        self.assertFalse(embedded_swift.is_symlink())
        self.assertEqual(hashlib.sha256(embedded_swift.read_bytes()).hexdigest(),
                         hashlib.sha256((destination / "libWebKitSwift.dylib").read_bytes()).hexdigest())
        policy = (destination / "WebKit.framework/Versions/A/Resources/com.apple.WebKit.NetworkProcess.sb").read_text()
        self.assertIn('(deny mach-lookup\n    (global-name "com.apple.dnssd.service")', policy)
        self.assertIn('(global-name "com.apple.system.opendirectoryd.libinfo")', policy)
        self.assertIn('(remote tcp "localhost:45100")', policy)
        self.assertEqual(policy.count('(allow network-outbound (remote tcp "localhost:45100"))'), 1)
        self.assertEqual(policy.count('(allow syscall-unix (syscall-number SYS_socket))'), 1)
        self.assertNotIn('(allow file-read* (literal "/Library/Preferences/com.apple.networkd.plist"))', policy)
        self.assertIn("NeAntik removes WebKit's unrestricted UDP grant", policy)
        self.assertIn("NeAntik removes the state-flag-dependent general TCP/UDP grant", policy)
        self.assertNotIn('(allow network*', policy)
        self.assertNotIn('(state-flag "BlockNetworkAccess")', policy)
        self.assertNotIn('(remote tcp))', policy)
        self.assertNotIn('(remote udp))', policy)
        self.assertNotIn('/private/var/run/mDNSResponder', policy)
        self.assertNotIn('(deny network-outbound', policy)
        self.assertNotIn('(system-network)', policy)
        self.assertNotIn('com.apple.networkserviceproxy.fetch-token', policy)
        self.assertNotIn('com.apple.webkit.adattributiond.service', policy)
        self.assertNotIn('org.webkit.pcmtestdaemon.service', policy)
        self.assertNotIn('com.apple.webkit.webpushd.service', policy)
        self.assertNotIn('com.apple.webkit.webpushd.relocatable.service', policy)
        self.assertNotIn('org.webkit.webpushtestdaemon.service', policy)
        for service in (
            "com.apple.cfnetwork.AuthBrokerAgent",
            "com.apple.cfnetwork.cfnetworkagent",
            "com.apple.nesessionmanager.flow-divert-token",
            "com.apple.nesessionmanager.content-filter",
            "com.apple.mobileasset.autoasset",
            "com.apple.webprivacyd",
            "com.apple.WebPrivacy.Service",
        ):
            self.assertNotIn(f'(global-name "{service}")', policy)
        self.assertIn('(global-name "com.apple.logd")', policy)
        self.assertIn("NeAntik does not invoke WebKit's delegated system-network grants", policy)
        self.assertIn("NeAntik removes the Network Service Proxy token delegation", policy)
        self.assertEqual(result["networkSandbox"]["baseSHA256"], self.manifest["networkSandbox"]["baseSHA256"])
        self.assertNotEqual(result["networkSandbox"]["patchedSHA256"], result["networkSandbox"]["baseSHA256"])
        self.assertIn("deny resolver mach endpoints", result["networkSandbox"]["policy"])
        self.assertTrue(result["networkSandbox"]["removedInheritedNetworkStarGrant"])
        self.assertTrue(result["networkSandbox"]["removedDelegatedSystemNetworkInvocation"])
        self.assertTrue(result["networkSandbox"]["removedNetworkServiceProxyTokenGrant"])
        self.assertEqual(result["networkSandbox"]["removedWebPushDaemonGrants"], 3)
        self.assertEqual(result["networkSandbox"]["removedAttributionServiceGrants"], 1)
        self.assertEqual(result["networkSandbox"]["removedPrivateClickTestServiceGrants"], 1)
        self.assertEqual(result["networkSandbox"]["removedDelegatedNetworkServiceGrants"], 7)
        self.assertTrue(result["networkSandbox"]["brokerGrantUnconditional"])
        self.assertTrue(result["networkSandbox"]["socketSyscallGranted"])
        self.assertFalse((destination / "WebKit.framework/Versions/A/Headers").exists())
        self.assertFalse((destination / "WebKit.framework/Versions/A/_CodeSignature").exists())
        self.assertFalse(result["launchQualified"])

    def test_refuses_external_runtime_symlink(self):
        outside = Path(self.temp.name) / "outside"
        outside.write_text("do not copy")
        (self.root / "WebKit.framework/Versions/A/Resources/leak").symlink_to(outside)
        with self.assertRaisesRegex(stage.ContractError, "unsafe or dangling symlink"):
            stage.copy_runtime(self.root, Path(self.temp.name) / "Frameworks", self.manifest)

    def test_refuses_existing_destination_without_erasing_it(self):
        destination = Path(self.temp.name) / "Frameworks"
        destination.mkdir()
        marker = destination / "keep"
        marker.write_text("preserve")
        with self.assertRaisesRegex(stage.ContractError, "must not already exist"):
            stage.copy_runtime(self.root, destination, self.manifest)
        self.assertEqual(marker.read_text(), "preserve")

    def test_refuses_symlinked_destination_parent(self):
        real = Path(self.temp.name) / "real"
        real.mkdir()
        alias = Path(self.temp.name) / "alias"
        alias.symlink_to(real)
        with self.assertRaisesRegex(stage.ContractError, "physical directory"):
            stage.copy_runtime(self.root, alias / "Frameworks", self.manifest)
        self.assertFalse((real / "Frameworks").exists())

    def test_manifest_rejects_path_traversal(self):
        value = dict(self.manifest)
        value["runtimeItems"] = ["../outside"]
        path = Path(self.temp.name) / "manifest.json"
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(stage.ContractError, "unsafe item"):
            stage.load_manifest(path)

    def test_manifest_rejects_unreviewed_policy_revision(self):
        value = json.loads(json.dumps(self.manifest))
        value["networkSandbox"]["policyRevision"] = 11
        path = Path(self.temp.name) / "manifest.json"
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(stage.ContractError, "network sandbox pin is malformed"):
            stage.load_manifest(path)

    def test_refuses_unpinned_sandbox_policy_and_preserves_source(self):
        self.manifest["networkSandbox"]["baseSHA256"] = "0" * 64
        original = self.policy.read_bytes()
        with self.assertRaisesRegex(stage.ContractError, "source hash"):
            stage.copy_runtime(self.root, Path(self.temp.name) / "Frameworks", self.manifest)
        self.assertEqual(self.policy.read_bytes(), original)

    def test_refuses_network_policy_drift_without_rewriting_source(self):
        self.policy.write_text(self.policy.read_text().replace('(allow network*', '(allow network'))
        self.manifest["networkSandbox"]["baseSHA256"] = hashlib.sha256(self.policy.read_bytes()).hexdigest()
        original = self.policy.read_bytes()
        with self.assertRaisesRegex(stage.ContractError, "network grants changed"):
            stage.copy_runtime(self.root, Path(self.temp.name) / "Frameworks", self.manifest)
        self.assertEqual(self.policy.read_bytes(), original)

    def test_refuses_missing_webpush_grant_without_rewriting_source(self):
        self.policy.write_text(self.policy.read_text().replace(
            '(allow mach-lookup (global-name "com.apple.webkit.webpushd.service"))\n', '', 1))
        self.manifest["networkSandbox"]["baseSHA256"] = hashlib.sha256(self.policy.read_bytes()).hexdigest()
        original = self.policy.read_bytes()
        with self.assertRaisesRegex(stage.ContractError, "network grants changed"):
            stage.copy_runtime(self.root, Path(self.temp.name) / "Frameworks", self.manifest)
        self.assertEqual(self.policy.read_bytes(), original)

    def test_refuses_missing_delegated_network_service_without_rewriting_source(self):
        self.policy.write_text(self.policy.read_text().replace(
            '    (global-name "com.apple.cfnetwork.AuthBrokerAgent")\n', '', 1))
        self.manifest["networkSandbox"]["baseSHA256"] = hashlib.sha256(self.policy.read_bytes()).hexdigest()
        original = self.policy.read_bytes()
        with self.assertRaisesRegex(stage.ContractError, "network grants changed"):
            stage.copy_runtime(self.root, Path(self.temp.name) / "Frameworks", self.manifest)
        self.assertEqual(self.policy.read_bytes(), original)

    def test_refuses_upstream_socket_syscall_drift_without_rewriting_source(self):
        self.policy.write_text(self.policy.read_text().replace(
            'SYS_socketpair', 'SYS_socket', 1))
        self.manifest["networkSandbox"]["baseSHA256"] = hashlib.sha256(self.policy.read_bytes()).hexdigest()
        original = self.policy.read_bytes()
        with self.assertRaisesRegex(stage.ContractError, "network grants changed"):
            stage.copy_runtime(self.root, Path(self.temp.name) / "Frameworks", self.manifest)
        self.assertEqual(self.policy.read_bytes(), original)

    def _webkit_v3_source_and_manifest(self):
        source = Path(self.temp.name) / "upstream"
        source.mkdir()
        components = ("CSSDocumentation", "CodeMirror", "Esprima", "three.js")
        notices = []
        for component in components:
            rel = f"Source/WebInspectorUI/UserInterface/External/{component}/LICENSE"
            path = source / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"Pinned license for {component}\n")
            notices.append({
                "component": component,
                "sourcePath": rel,
                "destinationPath": f"WebInspectorUI.framework/Versions/A/Resources/External/{component}/LICENSE",
                "gitBlob": "0" * 40,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            })
        commit = "a" * 40
        for item in notices:
            payload = (source / item["sourcePath"]).read_bytes()
            item["gitBlob"] = hashlib.sha1(
                b"blob " + str(len(payload)).encode("ascii") + b"\0" + payload
            ).hexdigest()
        web_inspector = self.root / "WebInspectorUI.framework/Versions/A"
        (web_inspector / "Resources").mkdir(parents=True)
        (web_inspector / "Resources/Info.plist").write_text("fixture")
        (web_inspector / "WebInspectorUI").write_bytes(MACHO)
        manifest = json.loads(json.dumps(self.manifest))
        manifest["schemaVersion"] = 3
        manifest["upstream"]["commit"] = commit
        manifest["runtimeItems"].append("WebInspectorUI.framework")
        manifest["webInspectorLicenseFiles"] = notices
        manifest_path = Path(self.temp.name) / "manifest-v3.json"
        manifest_path.write_text(json.dumps(manifest))
        return source, stage.load_manifest(manifest_path)

    def test_v3_copies_exact_pinned_webinspector_license_files(self):
        source, manifest = self._webkit_v3_source_and_manifest()
        self.assertFalse((source / ".git").exists())
        destination = Path(self.temp.name) / "Frameworks-v3"
        result = stage.copy_runtime(self.root, destination, manifest, source)
        self.assertEqual(len(result["webInspectorLicenseFiles"]), 4)
        for item in manifest["webInspectorLicenseFiles"]:
            copied = destination / item["destinationPath"]
            original = source / item["sourcePath"]
            self.assertEqual(copied.read_bytes(), original.read_bytes())
            self.assertEqual(stage.digest(copied), item["sha256"])

    def test_v3_refuses_license_drift_before_creating_output(self):
        source, manifest = self._webkit_v3_source_and_manifest()
        (source / manifest["webInspectorLicenseFiles"][0]["sourcePath"]).write_text("drift\n")
        destination = Path(self.temp.name) / "Frameworks-v3"
        with self.assertRaisesRegex(stage.ContractError, "license bytes changed"):
            stage.copy_runtime(self.root, destination, manifest, source)
        self.assertFalse(destination.exists())

    def test_v4_copies_pinned_official_compatibility_span_binary(self):
        source, manifest = self._webkit_v3_source_and_manifest()
        manifest["schemaVersion"] = 4
        manifest["swiftCompatibilitySpan"] = {
            "packageSHA256": "8fd03185b98fe27f54f8f523867e297ca5ff12bf8d4d63a6c627d7c60e286e845",
            "sourcePath": "runtime/owned-webkit/libswiftCompatibilitySpan.dylib",
            "destinationPath": "libswiftCompatibilitySpan.dylib",
            "bytes": 156544,
            "sha256": "b4256b38185e963651938ed0406c6c8ec54299621c7fa53c5e9a0a325ca5fe4f",
        }
        destination = Path(self.temp.name) / "Frameworks-v4"
        result = stage.copy_runtime(self.root, destination, manifest, source)
        copied = destination / "libswiftCompatibilitySpan.dylib"
        self.assertEqual(copied.stat().st_size, 156544)
        self.assertEqual(stage.digest(copied), manifest["swiftCompatibilitySpan"]["sha256"])
        self.assertEqual(result["swiftCompatibilitySpan"]["packageSHA256"],
                         manifest["swiftCompatibilitySpan"]["packageSHA256"])

    def test_v4_manifest_rejects_wrong_compatibility_span_hash(self):
        value = json.loads((SCRIPT.parents[1] / "runtime/webkit-production-staging-v4.json").read_text())
        value["swiftCompatibilitySpan"]["sha256"] = "0" * 64
        path = Path(self.temp.name) / "manifest-v4.json"
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(stage.ContractError, "not the pinned official binary"):
            stage.load_manifest(path)

    def test_refuses_relay_port_drift_from_broker(self):
        self.manifest["networkSandbox"]["relayPort"] = 58632
        with self.assertRaisesRegex(stage.ContractError, "does not match the WebKit broker"):
            stage.copy_runtime(self.root, Path(self.temp.name) / "Frameworks", self.manifest)


if __name__ == "__main__":
    unittest.main()
