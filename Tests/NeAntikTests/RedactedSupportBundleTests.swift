import Foundation
import Testing
@testable import NeAntik

struct RedactedSupportBundleTests {
    @Test
    func bundleContainsOnlyAggregateStatusAndRuntimeProvenance() throws {
        let first = BrowserProfile(name: "Private profile")
        let second = BrowserProfile(name: "Another profile", isArchived: true)
        let bundle = try RedactedSupportBundle(
            managerVersion: "0.7.4",
            managerBuild: "74",
            runtime: nil,
            runtimeAvailability: .missing,
            profiles: [first, second],
            folderCount: 1,
            processStates: [.stopped, .recoveryRequired],
            generatedAt: Date(timeIntervalSince1970: 10)
        )

        #expect(bundle.workspace.profileCount == 2)
        #expect(bundle.workspace.activeProfileCount == 1)
        #expect(bundle.workspace.archivedProfileCount == 1)
        #expect(bundle.health.failureCount == 1)
        #expect(bundle.health.recoveryCount == 1)
        #expect(bundle.runtime.status == .unavailable)
        #expect(bundle.runtime.version == nil)
        #expect(bundle.checks.isEmpty)
        #expect(bundle.performance.runtimeStatus == .unverified)

        let data = try encoded(bundle)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(first.name))
        #expect(!text.contains(second.name))
        #expect(!text.contains(first.id.uuidString))
        #expect(!text.contains("BrowserData"))
        #expect(!text.contains("proxy"))
        #expect(!text.contains("cookie"))
    }

    @Test
    func runtimeHashesAndSignatureAreAllowlisted() throws {
        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: URL(fileURLWithPath: "/private/runtime"),
            source: "embedded",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "153.0.8010.52",
                architectures: ["arm64"],
                codeSignatureValid: true,
                executableSHA256: String(repeating: "a", count: 64),
                frameworkSHA256: String(repeating: "b", count: 64)
            )
        )
        let bundle = try RedactedSupportBundle(
            managerVersion: "0.7.4",
            managerBuild: "74",
            runtime: runtime,
            runtimeAvailability: .ready,
            profiles: [],
            folderCount: 0,
            processStates: []
        )

        #expect(bundle.runtime.status == .ready)
        #expect(bundle.runtime.architecture == "arm64")
        #expect(bundle.runtime.signature == .valid)
        #expect(bundle.runtime.executableHash?.count == 64)
        #expect(bundle.runtime.frameworkHash?.count == 64)
    }

    @Test
    func invalidManagerOrInconsistentWorkspaceFailsClosed() {
        #expect(throws: RedactedSupportBundleError.managerMetadataUnavailable) {
            try RedactedSupportBundle(
                managerVersion: "unknown",
                managerBuild: "74",
                runtime: nil,
                runtimeAvailability: .missing,
                profiles: [],
                folderCount: 0,
                processStates: []
            )
        }

        let profile = BrowserProfile(name: "Profile")
        #expect(throws: RedactedSupportBundleError.inconsistentWorkspace) {
            try RedactedSupportBundle(
                managerVersion: "0.7.4",
                managerBuild: "74",
                runtime: nil,
                runtimeAvailability: .missing,
                profiles: [profile],
                folderCount: 0,
                processStates: []
            )
        }
    }

    private func encoded(_ bundle: RedactedSupportBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }
}
