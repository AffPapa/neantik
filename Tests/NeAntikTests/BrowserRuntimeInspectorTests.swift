import Foundation
import Testing
@testable import NeAntik

struct BrowserRuntimeInspectorTests {
    @Test
    func readsArm64MachOAndBundleVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contents = root.appendingPathComponent(
            "Patched Chromium.app/Contents",
            isDirectory: true
        )
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )

        let executable = macOS.appendingPathComponent("Chromium")
        try Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x0C, 0x00, 0x00, 0x01
        ]).write(to: executable)
        let frameworkDirectory = contents.appendingPathComponent(
            "Frameworks/Chromium Framework.framework/Versions/1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: frameworkDirectory,
            withIntermediateDirectories: true
        )
        try Data("framework".utf8).write(
            to: frameworkDirectory.appendingPathComponent(
                "Chromium Framework"
            )
        )

        let plist: [String: Any] = [
            "CFBundleShortVersionString": "145.2.1"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        let inspection = BrowserRuntimeInspector.inspect(
            executableURL: executable
        )

        #expect(inspection.version == "145.2.1")
        #expect(inspection.architectures == ["arm64"])
        #expect(inspection.supportsAppleSilicon)
        #expect(
            inspection.executableSHA256 ==
                "6eca5cc86a53c80d74e777fffd48ee46b98f06a8b448d18106af49ac0862b875"
        )
        #expect(
            inspection.frameworkSHA256 ==
                "06a61df042ad775e8bdd27666ac077a3331e5eb3215d0351ba292bce7e96505b"
        )
    }

    @Test
    func rejectsIntelOnlyMachO() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: executable) }
        try Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x07, 0x00, 0x00, 0x01
        ]).write(to: executable)

        let inspection = BrowserRuntimeInspector.inspect(
            executableURL: executable
        )

        #expect(inspection.architectures == ["x86_64"])
        #expect(!inspection.supportsAppleSilicon)
    }
}
