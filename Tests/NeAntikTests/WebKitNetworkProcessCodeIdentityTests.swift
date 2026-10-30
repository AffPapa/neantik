import Foundation
import Testing
@testable import NeAntik

@Suite struct WebKitNetworkProcessCodeIdentityTests {
    private func pin(_ identifier: String = WebKitNetworkProcessCodeIdentity.identifier,
                     executable: String = "app.neantik.desktop.webkit.Networking.Development",
                     sha: String = String(repeating: "a", count: 64),
                     cdHash: String = String(repeating: "b", count: 40)) -> [String: Any] {
        ["schemaVersion": 1, "identifier": identifier, "executable": executable,
         "sha256": sha, "cdHash": cdHash]
    }

    @Test func pinIsStrictlyBoundToTheOwnedNetworkingService() throws {
        let parsed = try WebKitNetworkProcessCodeIdentity.pin(propertyList: pin())
        #expect(parsed.identifier == WebKitNetworkProcessCodeIdentity.identifier)
        #expect(parsed.executable == "app.neantik.desktop.webkit.Networking.Development")
        #expect(parsed.cdHashBytes.count == 20)
        for malformed in [
            pin().merging(["schemaVersion": true]) { _, new in new },
            pin("com.apple.WebKit.Networking"),
            pin(executable: "../Networking"),
            pin(sha: String(repeating: "A", count: 64)),
            pin(cdHash: String(repeating: "g", count: 40)),
            pin().merging(["extra": "untrusted"]) { _, new in new },
        ] {
            #expect(throws: WebKitNetworkProcessCodeIdentity.Failure.self) {
                try WebKitNetworkProcessCodeIdentity.pin(propertyList: malformed)
            }
        }
    }

    @Test func ownerLocatorMustMatchFullProcessGenerationAndUserTuple() {
        let owner = WebKitOwnedNetworkProcessPID.Owner(
            pid: 512, startedAtSeconds: 100, startedAtMicroseconds: 123,
            userID: 501, parentPID: 1)
        let matching = WebKitOwnedNetworkProcessPID.ProcessSnapshot(
            pid: 512, startedAtSeconds: 100, startedAtMicroseconds: 123,
            userID: 501, parentPID: 1)
        #expect(WebKitNetworkProcessCodeIdentity.matches(owner, snapshot: matching))
        let changed = [
            WebKitOwnedNetworkProcessPID.ProcessSnapshot(pid: 513, startedAtSeconds: 100,
                startedAtMicroseconds: 123, userID: 501, parentPID: 1),
            WebKitOwnedNetworkProcessPID.ProcessSnapshot(pid: 512, startedAtSeconds: 101,
                startedAtMicroseconds: 123, userID: 501, parentPID: 1),
            WebKitOwnedNetworkProcessPID.ProcessSnapshot(pid: 512, startedAtSeconds: 100,
                startedAtMicroseconds: 124, userID: 501, parentPID: 1),
            WebKitOwnedNetworkProcessPID.ProcessSnapshot(pid: 512, startedAtSeconds: 100,
                startedAtMicroseconds: 123, userID: 502, parentPID: 1),
            WebKitOwnedNetworkProcessPID.ProcessSnapshot(pid: 512, startedAtSeconds: 100,
                startedAtMicroseconds: 123, userID: 501, parentPID: 42),
        ]
        for snapshot in changed {
            #expect(!WebKitNetworkProcessCodeIdentity.matches(owner, snapshot: snapshot))
        }
        #expect(!WebKitNetworkProcessCodeIdentity.matches(owner, snapshot: nil))
    }

    @Test func executableMustLiveAtTheExactPhysicalNestedXPCPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webkit-network-process-pin-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = root.appendingPathComponent("NeAntik.app", isDirectory: true)
        try FileManager.default.createDirectory(at: manager.appendingPathComponent("Contents", isDirectory: true),
                                                withIntermediateDirectories: true)
        let managerInfo: [String: Any] = ["CFBundleIdentifier": WebKitHostCodeIdentity.managerIdentifier]
        try PropertyListSerialization.data(fromPropertyList: managerInfo, format: .xml, options: 0)
            .write(to: manager.appendingPathComponent("Contents/Info.plist"))
        let service = manager.appendingPathComponent(WebKitNetworkProcessCodeIdentity.serviceRelativePath,
                                                     isDirectory: true)
        let contents = service.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": WebKitNetworkProcessCodeIdentity.identifier,
            "CFBundleExecutable": "app.neantik.desktop.webkit.Networking.Development",
            "CFBundlePackageType": "XPC!",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("app.neantik.desktop.webkit.Networking.Development")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x00]).write(to: executable)
        #expect(try WebKitNetworkProcessCodeIdentity.executableURL(
            in: manager, expectedExecutable: "app.neantik.desktop.webkit.Networking.Development") == executable)

        let devInfo: [String: Any] = ["CFBundleIdentifier":
            NeAntikApplicationEnvironment.developmentBundleIdentifier]
        try PropertyListSerialization.data(fromPropertyList: devInfo, format: .xml, options: 0)
            .write(to: manager.appendingPathComponent("Contents/Info.plist"))
        #expect(try WebKitNetworkProcessCodeIdentity.executableURL(
            in: manager, expectedExecutable: "app.neantik.desktop.webkit.Networking.Development") == executable)

        let unknownInfo: [String: Any] = ["CFBundleIdentifier":
            NeAntikApplicationEnvironment.developmentBundleIdentifier + ".other"]
        try PropertyListSerialization.data(fromPropertyList: unknownInfo, format: .xml, options: 0)
            .write(to: manager.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: WebKitNetworkProcessCodeIdentity.Failure.self) {
            try WebKitNetworkProcessCodeIdentity.executableURL(
                in: manager, expectedExecutable: "app.neantik.desktop.webkit.Networking.Development")
        }
        try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
            .write(to: manager.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: WebKitNetworkProcessCodeIdentity.Failure.self) {
            try WebKitNetworkProcessCodeIdentity.executableURL(
                in: manager, expectedExecutable: "app.neantik.desktop.webkit.Networking.Development")
        }
        try PropertyListSerialization.data(fromPropertyList: devInfo, format: .xml, options: 0)
            .write(to: manager.appendingPathComponent("Contents/Info.plist"))

        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable,
                                                   withDestinationURL: root.appendingPathComponent("outside"))
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: root.appendingPathComponent("outside"))
        #expect(throws: WebKitNetworkProcessCodeIdentity.Failure.self) {
            try WebKitNetworkProcessCodeIdentity.executableURL(
                in: manager, expectedExecutable: "app.neantik.desktop.webkit.Networking.Development")
        }
    }
}
