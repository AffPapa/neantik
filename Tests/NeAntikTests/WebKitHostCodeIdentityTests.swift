import Foundation
import Darwin
import Testing
@testable import NeAntik

@Suite struct WebKitHostCodeIdentityTests {
    #if NEANTIK_WEBKIT_PROXY_PRODUCTION
    @Test func detachedPresenterRequiresExactProductionMetadataOnBothBundles() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let executable = app.appendingPathComponent(WebKitHostCodeIdentity.hostExecutableRelativePath)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let managerInfo = app.appendingPathComponent("Contents/Info.plist")
        let hostInfo = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let key = WebKitHostCodeIdentity.presenterCapabilityKey
        func write(_ manager: Any?, _ host: Any?, managerID: String = WebKitHostCodeIdentity.managerIdentifier) throws {
            let definitions: [(URL, String, Any?)] = [
                (managerInfo, managerID, manager),
                (hostInfo, WebKitHostCodeIdentity.hostIdentifier, host)
            ]
            for (destination, id, capability) in definitions {
                var info: [String: Any] = ["CFBundleIdentifier": id]
                info[key] = capability
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                    .write(to: destination)
            }
        }
        try write(nil, nil)
        #expect(try WebKitHostCodeIdentity.qaSessionTransport(for: executable) == .ordinary)
        try write(true, true)
        #expect(try WebKitHostCodeIdentity.qaSessionTransport(for: executable) == .detachedPresenter)
        for (manager, host) in [(true, nil), (nil, true), (true, false), (1, true)] as [(Any?, Any?)] {
            try write(manager, host)
            #expect(throws: WebKitHostCodeIdentity.Failure.unsafeBundle) {
                try WebKitHostCodeIdentity.qaSessionTransport(for: executable)
            }
        }
        try write(true, true, managerID: "app.neantik.desktop.dev")
        #expect(throws: WebKitHostCodeIdentity.Failure.unsafeBundle) {
            try WebKitHostCodeIdentity.qaSessionTransport(for: executable)
        }
    }
    #endif

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    @Test func privateSocketModeRequiresExactBooleanAndDetachedDevIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/NeAntikWebKitHost")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let infoURL = contents.appendingPathComponent("Info.plist")
        func write(_ info: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: infoURL)
        }
        var info: [String: Any] = [
            "CFBundleIdentifier": "app.neantik.desktop.dev.webkit-host",
            "NeAntikOwnedWebKitPrivateSuccessorV1": ["releaseQualified": false],
            "NeAntikQADetachedSession": true
        ]
        try write(info)
        #expect(try WebKitHostCodeIdentity.qaSessionTransport(for: executable) == .detachedPipe)
        info["NeAntikQADetachedSocketTransportV1"] = true
        try write(info)
        #expect(try WebKitHostCodeIdentity.qaSessionTransport(for: executable) == .detachedSocket)
        info["NeAntikQAMetalFrameTransportV1"] = true
        try write(info)
        #expect(try WebKitHostCodeIdentity.qaSessionTransport(for: executable) == .detachedMetal)
        info["NeAntikQADetachedSocketTransportV1"] = 1
        try write(info)
        #expect(throws: WebKitHostCodeIdentity.Failure.unsafeBundle) {
            try WebKitHostCodeIdentity.qaSessionTransport(for: executable)
        }
    }
    #endif

    @Test func failuresExplainTheSafeActionWithoutExposingPathsOrSecrets() {
        #expect(WebKitHostCodeIdentity.Failure.hostHashMismatch.errorDescription ==
                "Файл WebKit-host не совпадает с проверочной записью приложения. Нужна новая сборка.")
        #expect(WebKitHostCodeIdentity.Failure.unsafeBundle.errorDescription ==
                "Пакет отдельного WebKit неполный или изменён. Профиль не запускался.")
    }

    @Test func pinAcceptsOnlyExactVersionedHelperIdentity() throws {
        #expect(WebKitHostCodeIdentity.expectedHostIdentifier(
            for: WebKitHostCodeIdentity.managerIdentifier) == WebKitHostCodeIdentity.hostIdentifier)
        #expect(WebKitHostCodeIdentity.isSupportedHostIdentifier(WebKitHostCodeIdentity.hostIdentifier))
        #expect(WebKitHostCodeIdentity.expectedHostIdentifier(
            for: NeAntikApplicationEnvironment.developmentBundleIdentifier)
            == NeAntikApplicationEnvironment.developmentBundleIdentifier + ".webkit-host")
        #expect(WebKitHostCodeIdentity.isSupportedHostIdentifier(
            NeAntikApplicationEnvironment.developmentBundleIdentifier + ".webkit-host"))
        #expect(WebKitHostCodeIdentity.expectedHostIdentifier(
            for: NeAntikApplicationEnvironment.developmentBundleIdentifier + ".extra") == nil)
        #expect(!WebKitHostCodeIdentity.isSupportedHostIdentifier(
            NeAntikApplicationEnvironment.developmentBundleIdentifier + ".webkit-host.extra"))
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

        // A notarized, optimized Dev QA bundle has the same exact host naming
        // contract as a Debug bundle. This used to fail because the Dev case
        // was compiled out whenever DEBUG was absent.
        let developmentManagerID = NeAntikApplicationEnvironment.developmentBundleIdentifier
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": developmentManagerID,
            "CFBundleExecutable": "NeAntik",
        ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": developmentManagerID + ".webkit-host",
            "CFBundleExecutable": "NeAntikWebKitHost",
            "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0).write(to: helper.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist"))
        #expect(try WebKitHostCodeIdentity.helperURL(in: app) == helper)

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

    @Test func managerIdentityAcceptsReleaseAndExactQAIdentifiersInEveryConfiguration() throws {
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
        try writeIdentifier(NeAntikApplicationEnvironment.developmentBundleIdentifier)
        #expect(WebKitHostCodeIdentity.expectedManagerIdentifier(in: root)
                == NeAntikApplicationEnvironment.developmentBundleIdentifier)
        try writeIdentifier(NeAntikApplicationEnvironment.developmentBundleIdentifier + ".extra")
        #expect(WebKitHostCodeIdentity.expectedManagerIdentifier(in: root) == nil)
        try writeIdentifier("app.neantik.desktop.untrusted")
        #expect(WebKitHostCodeIdentity.expectedManagerIdentifier(in: root) == nil)
    }

    @Test func expectedTeamFailsClosedWhenManagerIsUnsignedOrMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webkit-manager-team-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": WebKitHostCodeIdentity.managerIdentifier,
            "CFBundleExecutable": "NeAntik",
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("unsigned manager fixture".utf8).write(to: macOS.appendingPathComponent("NeAntik"))

        #expect(WebKitHostCodeIdentity.expectedTeamIdentifier(in: root) == nil)
    }

    @Test func parentCannotClaimAChildForAnotherProcess() {
        let unrelatedBundle = URL(fileURLWithPath: "/tmp/unrelated.app", isDirectory: true)
        #expect(WebKitHostCodeIdentity.verifyChild(
            processID: getpid(), expectedParentPID: getpid() + 1,
            managerBundle: unrelatedBundle) == nil)
    }
}
