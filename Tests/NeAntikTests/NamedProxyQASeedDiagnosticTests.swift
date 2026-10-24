import Foundation
import Testing
@testable import NeAntik

/// Opt-in fixture preflight. It must run before another signed QA attempt.
@MainActor
struct NamedProxyQASeedDiagnosticTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_QA_SEED_ROOT"] != nil))
    func exactSyntheticSeedLoads() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["NEANTIK_QA_SEED_ROOT"])
        guard raw.hasPrefix("/private/tmp/neantik-") else {
            Issue.record("QA seed root is outside the private temporary namespace")
            return
        }
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: raw, isDirectory: true))
        let data = try Data(contentsOf: paths.profilesFile)
        let decoded: [BrowserProfile]
        do {
            decoded = try ProfileStore.decodeProfiles(data)
        } catch DecodingError.dataCorrupted(let context) {
            Issue.record("QA seed dataCorrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)")
            return
        } catch DecodingError.keyNotFound(let key, let context) {
            Issue.record("QA seed keyNotFound \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
            return
        } catch {
            Issue.record("QA seed decode refused: \(type(of: error))")
            return
        }
        #expect(decoded.count == 2)
        let normalized = try ProfileStore.normalizedForIsolation(decoded)
        #expect(!normalized.changed)
        let store = ProfileStore(paths: paths)
        #expect(store.hasTrustedMetadata)
        #expect(store.profiles.count == 2)
        do {
            try await store.refreshExternalMetadata(force: true)
        } catch {
            Issue.record("QA seed external refresh refused: \(type(of: error)) \(error.localizedDescription)")
            return
        }
        #expect(store.hasTrustedMetadata)
        #expect(store.profiles.count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_QA_SEED_ROOT"] != nil))
    func overlappingWindowRefreshesKeepTrust() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["NEANTIK_QA_SEED_ROOT"])
        let seed = try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent("profiles.json"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-refresh-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try seed.write(to: root.appendingPathComponent("profiles.json"))
        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        #expect(store.hasTrustedMetadata)
        let first = Task { try await store.refreshExternalMetadata(force: true) }
        let second = Task { try await store.refreshExternalMetadata(force: true) }
        for task in [first, second] {
            do { try await task.value }
            catch is ProfileMetadataBusyError { /* contention preserves trust */ }
        }
        #expect(store.hasTrustedMetadata)
        #expect(store.profiles.count == 2)
    }
}
