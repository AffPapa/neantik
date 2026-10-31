import Foundation
import Testing
@testable import DirectUpdateCore

struct DirectUpdateOwnerClientTests {
    @Test func unbundledTestProcessCannotSupplyInstalledPolicyOrReuseAttempt() async throws {
        let client = DirectUpdateOwnerClient()
        let archive = URL(fileURLWithPath: "/private/tmp/neantik-client-nonexistent.zip")
        await #expect(throws: DirectUpdateInstallSessionError.identity) {
            try await client.inspect(archive: archive, manifest: Data([1]))
        }
        await #expect(throws: DirectUpdateOwnerClientError.self) {
            try await client.inspect(archive: archive, manifest: Data([1]))
        }
        await #expect(throws: DirectUpdateOwnerClientError.self) { try await client.consentAndHandoff() }
        try await client.cancelAndDrain()
    }
    @Test func cancellationBeforeInspectionNeverLaunchesAnOwner() async throws {
        let client = DirectUpdateOwnerClient()
        try await client.cancelAndDrain()
        await #expect(throws: CancellationError.self) {
            try await client.inspect(archive: URL(fileURLWithPath: "/private/tmp/neantik-client-missing.zip"), manifest: Data([1]))
        }
        await #expect(throws: DirectUpdateOwnerClientError.self) { try await client.consentAndHandoff() }
    }
}
