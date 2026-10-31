import Foundation
import Darwin
import Testing
@testable import NeAntik

/// Opt-in fixture preflight. It must run before another signed QA attempt.
@MainActor
struct NamedProxyQASeedDiagnosticTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_QA_GENERATE_TLS_TEMPLATE"] != nil))
    func generateModelEncodedIsolatedBlankTemplate() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["NEANTIK_QA_GENERATE_TLS_TEMPLATE"])
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        guard raw.hasPrefix("/private/tmp/neantik-"),
              root.deletingLastPathComponent().path == "/private/tmp",
              FileManager.default.fileExists(atPath: root.path) else {
            Issue.record("QA template root is not a private temporary directory")
            return
        }
        let profile = BrowserProfile(
            name: "QA isolated WebKit blank 20261021",
            startURL: "about:blank",
            startupMode: .startPage,
            engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1,
            proxy: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try ProfileStore.encodeProfiles([profile], encoder: encoder)
        #expect(try ProfileStore.decodeProfiles(payload).count == 1)
        let path = root.appendingPathComponent("profiles.json").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EEXIST) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: payload)
        try handle.synchronize()
        #expect((try Data(contentsOf: URL(fileURLWithPath: path))) == payload)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_QA_GENERATE_ROOT"] != nil))
    func generateModelEncodedDisposablePair() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["NEANTIK_QA_GENERATE_ROOT"])
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        guard raw.hasPrefix("/private/tmp/neantik-"),
              root.deletingLastPathComponent().path == "/private/tmp",
              FileManager.default.fileExists(atPath: root.path) else {
            Issue.record("QA output root is not a private temporary directory")
            return
        }
        var a = BrowserProfile(
            name: "Owned 145 QA A proxy",
            startURL: "http://neantik-proxy-qa.invalid:45102/proxy-a",
            startupMode: .startPage,
            engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1,
            proxy: ProxyConfiguration(kind: .http, host: "127.0.0.1", port: 45101, username: "")
        )
        let b = BrowserProfile(
            name: "Owned 145 QA B direct",
            startURL: "http://127.0.0.1:45102/direct-b",
            engine: .webkit,
            webKitRuntimeGeneration: .system,
            identity: a.identity
        )
        a.revision = 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try ProfileStore.encodeProfiles([a, b], encoder: encoder)
        #expect(try ProfileStore.decodeProfiles(payload).count == 2)
        for name in ["profiles.json", "profiles.previous.json"] {
            let path = root.appendingPathComponent(name).path
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EEXIST) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: payload)
            try handle.synchronize()
            try handle.close()
        }
    }

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
        let sharedInitialIdentity = decoded.count == 2 && decoded[0].identity == decoded[1].identity
        #expect(normalized.changed == sharedInitialIdentity)
        #expect(Set(normalized.profiles.map(\.identity.runtimeSeed)).count == normalized.profiles.count)
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
