import Foundation
import Darwin
import Testing
@testable import NeAntik

@Suite struct WebKitHostCodeIdentityTests {
    @Test func pinAcceptsOnlyExactVersionedHelperIdentity() throws {
        #expect(WebKitHostCodeIdentity.expectedHostIdentifier(
            for: WebKitHostCodeIdentity.managerIdentifier) == WebKitHostCodeIdentity.hostIdentifier)
        #expect(WebKitHostCodeIdentity.isSupportedHostIdentifier(WebKitHostCodeIdentity.hostIdentifier))
        #if DEBUG
        #expect(WebKitHostCodeIdentity.expectedHostIdentifier(
            for: NeAntikApplicationEnvironment.developmentBundleIdentifier)
            == NeAntikApplicationEnvironment.developmentBundleIdentifier + ".webkit-host")
        #expect(WebKitHostCodeIdentity.isSupportedHostIdentifier(
            NeAntikApplicationEnvironment.developmentBundleIdentifier + ".webkit-host"))
        #else
        #expect(WebKitHostCodeIdentity.expectedHostIdentifier(
            for: NeAntikApplicationEnvironment.developmentBundleIdentifier) == nil)
        #expect(!WebKitHostCodeIdentity.isSupportedHostIdentifier(
            NeAntikApplicationEnvironment.developmentBundleIdentifier + ".webkit-host"))
        #endif
        let value: [String: Any] = [
            "schemaVersion": 1,
            "identifier": WebKitHostCodeIdentity.hostIdentifier,
            "sha256": String(repeating: "a", count: 64),
            "cdHash": String(repeating: "b", count: 40),
        ]
        let pin = try WebKitHostCodeIdentity.Pin(propertyList: value)
        #expect(pin.identifier == WebKitHostCodeIdentity.hostIdentifier)
        #expect(pin.sha256 == String(repeating: "a", count: 64))
        #expect(pin.cdHashBytes.count == 20)

        for invalid in [
            value.merging(["unexpected": "field"]) { _, new in new },
            value.merging(["schemaVersion": true]) { _, new in new },
            value.merging(["identifier": "app.neantik.other-helper"]) { _, new in new },
            value.merging(["sha256": String(repeating: "A", count: 64)]) { _, new in new },
            value.merging(["cdHash": String(repeating: "g", count: 40)]) { _, new in new },
        ] {
            #expect(throws: WebKitHostCodeIdentity.Failure.malformedPin) {
                try WebKitHostCodeIdentity.Pin(propertyList: invalid)
            }
        }
    }

    @Test func helperPathRequiresPhysicalExpectedBundleLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webkit-host-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("NeAntik.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                 withIntermediateDirectories: true)
        let managerInfo: [String: String] = [
            "CFBundleIdentifier": WebKitHostCodeIdentity.managerIdentifier,
            "CFBundleExecutable": "NeAntik",
        ]
        try PropertyListSerialization.data(fromPropertyList: managerInfo, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let helper = app.appendingPathComponent(WebKitHostCodeIdentity.hostExecutableRelativePath)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("owned test executable".utf8).write(to: helper)
        let hostInfo: [String: String] = [
            "CFBundleIdentifier": WebKitHostCodeIdentity.hostIdentifier,
            "CFBundleExecutable": "NeAntikWebKitHost",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: hostInfo, format: .xml, options: 0)
            .write(to: helper.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Info.plist"))
        let path = try WebKitHostCodeIdentity.helperURL(in: app)
        #expect(path.standardizedFileURL == helper.standardizedFileURL)

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlinkApp = root.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkApp.appendingPathComponent("Contents"),
                                                 withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkApp.appendingPathComponent("Contents/Helpers", isDirectory: true),
            withDestinationURL: outside)
        #expect(throws: WebKitHostCodeIdentity.Failure.unsafeBundle) {
            try WebKitHostCodeIdentity.helperURL(in: symlinkApp)
        }
        #expect(throws: WebKitHostCodeIdentity.Failure.unsafeBundle) {
            try WebKitHostCodeIdentity.helperURL(in: root.appendingPathComponent("not-an-app"))
        }
    }

    @Test func managerIdentityAcceptsReleaseAndDebugOnlyQAIdentifiers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webkit-manager-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"),
                                                 withIntermediateDirectories: true)
        let infoURL = root.appendingPathComponent("Contents/Info.plist")
        func writeIdentifier(_ identifier: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": identifier],
                format: .xml,
                options: 0
            )
            try data.write(to: infoURL)
        }

        try writeIdentifier(WebKitHostCodeIdentity.managerIdentifier)
        #expect(WebKitHostCodeIdentity.expectedManagerIdentifier(in: root)
                == WebKitHostCodeIdentity.managerIdentifier)
        #if DEBUG
        try writeIdentifier(NeAntikApplicationEnvironment.developmentBundleIdentifier)
        #expect(WebKitHostCodeIdentity.expectedManagerIdentifier(in: root)
                == NeAntikApplicationEnvironment.developmentBundleIdentifier)
        #else
        try writeIdentifier(NeAntikApplicationEnvironment.developmentBundleIdentifier)
        #expect(WebKitHostCodeIdentity.expectedManagerIdentifier(in: root) == nil)
        #endif
        try writeIdentifier("app.neantik.desktop.untrusted")
        #expect(WebKitHostCodeIdentity.expectedManagerIdentifier(in: root) == nil)
    }

    @Test func parentCannotClaimAChildForAnotherProcess() {
        let unrelatedBundle = URL(fileURLWithPath: "/tmp/unrelated.app", isDirectory: true)
        #expect(WebKitHostCodeIdentity.verifyChild(
            processID: getpid(), expectedParentPID: getpid() + 1,
            managerBundle: unrelatedBundle) == nil)
    }
}
