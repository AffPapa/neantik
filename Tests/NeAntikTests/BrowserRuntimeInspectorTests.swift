import Foundation
import Testing
@testable import NeAntik

struct BrowserRuntimeInspectorTests {
    @Test
    func startupInspectionRejectsBrokenNestedRuntimeSignature() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = root.appendingPathComponent(
            "NeAntik Browser.app",
            isDirectory: true
        )
        let runtimeContents = runtime.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let runtimeMacOS = runtimeContents.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        let helper = runtimeContents.appendingPathComponent(
            "Helpers/Runtime Helper.app",
            isDirectory: true
        )
        let helperContents = helper.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let helperMacOS = helperContents.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        let helperResources = helperContents.appendingPathComponent(
            "Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeMacOS,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: helperMacOS,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: helperResources,
            withIntermediateDirectories: true
        )

        let runtimeExecutable = runtimeMacOS.appendingPathComponent(
            "NeAntik Browser"
        )
        let helperExecutable = helperMacOS.appendingPathComponent(
            "Runtime Helper"
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: runtimeExecutable
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: helperExecutable
        )
        try writeBundlePlist(
            executable: "NeAntik Browser",
            identifier: "app.neantik.test-runtime",
            to: runtimeContents.appendingPathComponent("Info.plist")
        )
        try writeBundlePlist(
            executable: "Runtime Helper",
            identifier: "app.neantik.test-runtime.helper",
            to: helperContents.appendingPathComponent("Info.plist")
        )
        let nestedResource = helperResources.appendingPathComponent(
            "sealed.txt"
        )
        try Data("original".utf8).write(to: nestedResource)

        try runCodesign(["--force", "--sign", "-", helper.path])
        try runCodesign([
            "--force", "--deep", "--sign", "-", runtime.path,
        ])

        #expect(
            BrowserRuntimeInspector.inspectForStartup(
                executableURL: runtimeExecutable
            ).codeSignatureValid == true
        )

        try Data("changed after signing".utf8).write(to: nestedResource)

        #expect(
            BrowserRuntimeInspector.inspectForStartup(
                executableURL: runtimeExecutable
            ).codeSignatureValid == false
        )
    }

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

    @Test
    func startupInspectionSkipsLargeRuntimeHashes() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: executable) }
        try Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x0C, 0x00, 0x00, 0x01
        ]).write(to: executable)

        let inspection = BrowserRuntimeInspector.inspectForStartup(
            executableURL: executable
        )

        #expect(inspection.architectures == ["arm64"])
        #expect(inspection.executableSHA256 == nil)
        #expect(inspection.frameworkSHA256 == nil)
    }

    private func writeBundlePlist(
        executable: String,
        identifier: String,
        to url: URL
    ) throws {
        let plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func runCodesign(_ arguments: [String]) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "BrowserRuntimeInspectorTests.codesign",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(decoding: data, as: UTF8.self),
                ]
            )
        }
    }
}
