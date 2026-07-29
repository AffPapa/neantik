import Foundation
import Testing
@testable import NeAntik

struct BrowserRuntimePreflightTests {
    @Test
    func acceptsExecutableSignedArm64Runtime() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: executable) }
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data()
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let runtime = BrowserRuntime(
            name: "Test Chromium",
            executableURL: executable,
            source: "Test",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "145.0",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )

        let result = BrowserRuntimePreflightValidator.validate(runtime)

        #expect(result.isReady)
        #expect(result.errors.isEmpty)
    }

    @Test
    func rejectsMissingOrIntelRuntime() {
        let runtime = BrowserRuntime(
            name: "Intel Chromium",
            executableURL: URL(fileURLWithPath: "/missing/chromium"),
            source: "Test",
            inspection: BrowserRuntimeInspection(
                version: "145.0",
                architectures: ["x86_64"],
                codeSignatureValid: false
            )
        )

        let result = BrowserRuntimePreflightValidator.validate(runtime)

        #expect(!result.isReady)
        #expect(result.errors.count == 3)
    }
}
