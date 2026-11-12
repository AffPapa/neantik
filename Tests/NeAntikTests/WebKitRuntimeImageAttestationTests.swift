import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct WebKitRuntimeImageAttestationTests {
    @Test func qaReceiptKeepsOnlyTheBoundedMixedImageCode() {
        let code = "runtime-ambiguousImages-owned1-system1-other0-entry0-appkit1"
        #expect(WebKitQAImageFailureReceipt.code(from:
            WebKitHostClient.Failure.childRefusedStartup(code: code)) == code)
        #expect(WebKitQAImageFailureReceipt.code(from:
            WebKitHostClient.Failure.childRefusedStartup(
                code: code + "-private-profile-path")) == nil)
        #expect(WebKitQAImageFailureReceipt.code(from:
            WebKitHostClient.Failure.childExited) == nil)
    }

    @Test func qaReceiptPersistsOnlyTheImageCodeInARealPrivateTmpFixture() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("neantik-image-receipt-" + UUID().uuidString,
                                    isDirectory: true)
        let contents = root.appendingPathComponent("Fixture.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.neantik.desktop.dev",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Fixture",
            "NeAntikDevelopmentFixtureRoot": root.path
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info,
            format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: contents.deletingLastPathComponent()))
        let code = "runtime-ambiguousImages-owned1-system1-other0-entry0-appkit1"
        WebKitQAImageFailureReceipt.record(
            WebKitHostClient.Failure.childRefusedStartup(code: code), root: root, bundle: bundle)
        let saved = try String(contentsOf: root.appendingPathComponent(
            "webkit-image-failure-qa.txt"), encoding: .utf8)
        #expect(saved == code + "\n")
        let startup = WebKitHostClient.Failure.childRefusedStartup(
            code: "runtime-missingRuntimeImage", stage: "identity-verified")
        WebKitQAImageFailureReceipt.recordStartup(startup, root: root, bundle: bundle)
        let startupFile = root.appendingPathComponent("webkit-startup-failure-qa.txt")
        #expect(try String(contentsOf: startupFile, encoding: .utf8) ==
            "failure=runtime-missingRuntimeImage stage=identity-verified\n")
        let profileID = UUID()
        WebKitQAImageFailureReceipt.recordNavigationStage(
            "qa-nav-url-code-m1003", profileID: profileID, root: root, bundle: bundle)
        let navigationFile = root.appendingPathComponent(
            "webkit-nav-stage-\(profileID.uuidString)-qa.txt")
        #expect(try String(contentsOf: navigationFile, encoding: .utf8) ==
            "stage=qa-nav-url-code-m1003\n")
        WebKitQAImageFailureReceipt.recordTLSStage(
            "qa-tls-eval-m9807", profileID: profileID, root: root, bundle: bundle)
        let tlsFile = root.appendingPathComponent(
            "webkit-tls-stage-\(profileID.uuidString)-qa.txt")
        #expect(try String(contentsOf: tlsFile, encoding: .utf8) ==
            "stage=qa-tls-eval-m9807\n")
        WebKitQAImageFailureReceipt.recordStartup(
            WebKitHostClient.Failure.childRefusedStartup(
                code: "runtime-private-profile-path", stage: "child-entry"),
            root: root, bundle: bundle)
        #expect(try String(contentsOf: startupFile, encoding: .utf8) ==
            "failure=runtime-missingRuntimeImage stage=identity-verified\n")
        #expect(!WebKitQAImageFailureReceipt.matchesFixtureRoot(
            root, fixture: "/private/tmp/neantik-another-qa"))
    }


    @Test func imageMultiplicityDiagnosticsContainOnlyBoundedCategories() {
        let app = URL(fileURLWithPath: "/private/tmp/owned-qa.app")
        let owned = app.appendingPathComponent("Contents/Frameworks/WebKit.framework/Versions/A/WebKit").path
        let system = "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"
        let foreign = "/private/tmp/private-profile-name/WebKit.framework/Versions/A/WebKit"
        let diagnostic = WebKitRuntimeImageAttestation.AmbiguousImageDiagnostic(
            imagePaths: [owned, owned, system, foreign, "/usr/lib/libSystem.B.dylib"], bundleURL: app)
        #expect(diagnostic.code == "ambiguousImages-owned2-system1-other1")
        #expect(WebKitRuntimeImageAttestation.AmbiguousImageDiagnostic(
            imagePaths: Array(repeating: foreign, count: 20), bundleURL: app).code
            == "ambiguousImages-owned0-system0-other9")
        var capture = WebKitStartupDiagnosticCapture.Tokens()
        capture.append(Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=runtime-\(diagnostic.code)\n".utf8))
        #expect(WebKitHostClient.childStartupDiagnosticCode(capture.snapshot) == "runtime-\(diagnostic.code)")
        let message = WebKitHostClient.Failure.childRefusedStartup(
            code: "runtime-\(diagnostic.code)").localizedDescription
        #expect(message.contains("две версии движка"))
        #expect(!message.contains(diagnostic.code))
        let phaseDiagnostic = WebKitRuntimeImageAttestation.AmbiguousImageDiagnostic(
            imagePaths: [owned, system], bundleURL: app,
            checkpoint: .init(systemAtEntry: 0, systemAfterAppKit: 1))
        #expect(phaseDiagnostic.code ==
            "ambiguousImages-owned1-system1-other0-entry0-appkit1")
        var phaseCapture = WebKitStartupDiagnosticCapture.Tokens()
        phaseCapture.append(Data(
            "NEANTIK_WEBKIT_STARTUP_FAILURE code=runtime-\(phaseDiagnostic.code)\n".utf8))
        #expect(WebKitHostClient.childStartupDiagnosticCode(phaseCapture.snapshot) ==
            "runtime-\(phaseDiagnostic.code)")
        for invalid in ["runtime-ambiguousImages-owned10-system0-other0", "runtime-ambiguousImages-owned1-system0-other0-private-profile-name"] {
            var rejected = WebKitStartupDiagnosticCapture.Tokens()
            rejected.append(Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=\(invalid)\n".utf8))
            #expect(rejected.snapshot.isEmpty)
        }
    }

    private func fixture(in directory: URL = FileManager.default.temporaryDirectory) throws -> (URL, URL, String) {
        let root = directory
            .appendingPathComponent("neantik-webkit-image-" + UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Host.app", isDirectory: true)
        let image = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("owned webkit fixture".utf8).write(to: image)
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }.joined()
        return (root, app, digest)
    }

    @Test func acceptsOnlyThePinnedFrameworkLoadedFromThisHostBundle() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")

        #expect(try WebKitRuntimeImageAttestation.verify(
            imagePaths: [expected.path], bundleURL: app, expectedSHA256: digest) == expected)
    }

    @Test func rejectsTheSameNamedSystemFramework() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: WebKitRuntimeImageAttestation.Failure.wrongRuntimeImage) {
            try WebKitRuntimeImageAttestation.verify(
                imagePaths: ["/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"],
                bundleURL: app, expectedSHA256: digest)
        }
    }

    @Test func refusesMissingOrDuplicateFrameworkImages() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")

        #expect(throws: WebKitRuntimeImageAttestation.Failure.missingRuntimeImage) {
            try WebKitRuntimeImageAttestation.verify(imagePaths: [], bundleURL: app,
                                                     expectedSHA256: digest)
        }
        #expect(throws: WebKitRuntimeImageAttestation.Failure.ambiguousRuntimeImage) {
            try WebKitRuntimeImageAttestation.verify(
                imagePaths: [expected.path,
                    "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"],
                bundleURL: app, expectedSHA256: digest)
        }
    }

    @Test func rejectsChangedBinaryAndMalformedPin() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")

        #expect(throws: WebKitRuntimeImageAttestation.Failure.runtimeHashMismatch) {
            try WebKitRuntimeImageAttestation.verify(imagePaths: [expected.path], bundleURL: app,
                                                     expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(throws: WebKitRuntimeImageAttestation.Failure.malformedPin) {
            try WebKitRuntimeImageAttestation.Pin(propertyList: [
                "schemaVersion": 2, "webKitSHA256": digest,
                "minimumOSVersion": "15.4.0", "extra": "not allowed"
            ])
        }
    }

    @Test func runtimePinCarriesAndEnforcesItsMinimumSystemVersion() throws {
        let digest = String(repeating: "a", count: 64)
        let pin = try WebKitRuntimeImageAttestation.Pin(propertyList: [
            "schemaVersion": 2, "webKitSHA256": digest,
            "minimumOSVersion": "15.4.0"
        ])
        #expect(pin.minimumOSVersion == "15.4.0")
        #expect(pin.supports(OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)))
        #expect(pin.supports(OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)))
        #expect(!pin.supports(OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 9)))
        #expect(!pin.supports(OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)))
        #expect(throws: WebKitRuntimeImageAttestation.Failure.malformedPin) {
            try WebKitRuntimeImageAttestation.Pin(propertyList: [
                "schemaVersion": 1, "webKitSHA256": digest,
                "minimumOSVersion": "15.4"
            ])
        }
    }

    @Test func verifiesTheExactNetworkSandboxResourceWhenTheHostRequiresIt() throws {
        let (root, app, _) = try fixture(in: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalApp = app
        let policy = physicalApp.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/Resources/com.apple.WebKit.NetworkProcess.sb")
        try FileManager.default.createDirectory(at: policy.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = Data("(version 1)".utf8)
        try bytes.write(to: policy)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
            bundleURL: physicalApp, signedSHA256: digest, required: true)
        let foundationAlias = physicalApp.resolvingSymlinksInPath()
        try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
            bundleURL: foundationAlias, signedSHA256: digest, required: true)
        try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
            bundleURL: physicalApp, signedSHA256: nil, required: false)
        #expect(throws: WebKitRuntimeImageAttestation.Failure.missingNetworkSandboxPin) {
            try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
                bundleURL: physicalApp, signedSHA256: nil, required: true)
        }
        #expect(throws: WebKitRuntimeImageAttestation.Failure.malformedNetworkSandboxPin) {
            try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
                bundleURL: physicalApp, signedSHA256: digest + "\n", required: true)
        }

        try Data("(version 2)".utf8).write(to: policy)
        #expect(throws: WebKitRuntimeImageAttestation.Failure.networkSandboxHashMismatch) {
            try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
                bundleURL: physicalApp, signedSHA256: digest, required: false)
        }
    }

    @Test func refusesNetworkSandboxAliasesAndOversizedResources() throws {
        let (root, app, _) = try fixture(in: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalRoot = root
        let physicalApp = app
        let resources = physicalApp.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/Resources")
        let policy = resources.appendingPathComponent("com.apple.WebKit.NetworkProcess.sb")
        let external = physicalRoot.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalPolicy = external.appendingPathComponent(policy.lastPathComponent)
        let bytes = Data("(version 1)".utf8)
        try bytes.write(to: externalPolicy)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: external)
        #expect(throws: WebKitRuntimeImageAttestation.Failure.unsafeNetworkSandboxPolicy) {
            try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
                bundleURL: physicalApp, signedSHA256: digest, required: true)
        }
        try FileManager.default.removeItem(at: resources)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: policy, withDestinationURL: externalPolicy)
        #expect(throws: WebKitRuntimeImageAttestation.Failure.unsafeNetworkSandboxPolicy) {
            try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
                bundleURL: physicalApp, signedSHA256: digest, required: true)
        }
        try FileManager.default.removeItem(at: policy)
        let oversized = Data(repeating: 0, count: (1 << 20) + 1)
        try oversized.write(to: policy)
        let oversizedDigest = SHA256.hash(data: oversized).map { String(format: "%02x", $0) }.joined()
        #expect(throws: WebKitRuntimeImageAttestation.Failure.unsafeNetworkSandboxPolicy) {
            try WebKitRuntimeImageAttestation.verifyNetworkSandbox(
                bundleURL: physicalApp, signedSHA256: oversizedDigest, required: true)
        }
    }

    @Test func rejectsFrameworkBundleSymlinks() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let framework = frameworks.appendingPathComponent("WebKit.framework", isDirectory: true)
        let outside = root.appendingPathComponent("outside.framework", isDirectory: true)
        try FileManager.default.moveItem(at: framework, to: outside)
        try FileManager.default.createSymbolicLink(at: framework, withDestinationURL: outside)

        #expect(throws: WebKitRuntimeImageAttestation.Failure.unsafeBundle) {
            try WebKitRuntimeImageAttestation.verify(imagePaths: [], bundleURL: app,
                                                     expectedSHA256: digest)
        }
    }
}
