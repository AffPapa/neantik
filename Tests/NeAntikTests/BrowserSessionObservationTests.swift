import Darwin
import Foundation
import Testing
@testable import NeAntik

struct BrowserSessionObservationTests {
    @MainActor @Test func finalPersistedFenceRefusesExternalChangeDuringObservationWait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-observation-fence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), reader = ProfileStore(paths: paths)
        let profile = try reader.upsert(BrowserProfile(name: "Observation fence"))
        let lease = lock(), receipt = ManagedBrowserSessionReceipt(generation: UUID(), lock: lease,
            runtimeVersion: "156.0.8078.12", configuredRoute: .direct, profileRevision: profile.revision)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(encoder.encode(lease), to: paths.lockFile(for: profile.id))
        let valid = try await Task.detached {
            try ManagedSessionLeaseReader.matchesPersistedContext(paths: paths, profile: profile, receipt: receipt)
        }.value
        #expect(valid)
        let gate = AsyncStream<Void>.makeStream()
        let suspendedRead = Task.detached {
            for await _ in gate.stream { break }
            return try ManagedSessionLeaseReader.matchesPersistedContext(paths: paths, profile: profile, receipt: receipt)
        }
        let writer = ProfileStore(paths: paths)
        var changed = profile; changed.startURL = "https://example.com/changed"
        let saved = try writer.upsert(changed)
        #expect(saved.revision != profile.revision)
        #expect(reader.profile(withID: profile.id)?.revision == profile.revision)
        gate.continuation.yield(()); gate.continuation.finish()
        await #expect(throws: BrowserProfileRevisionConflictError.self) { try await suspendedRead.value }
    }
    @MainActor @Test func freshMetadataCannotAdoptAnOlderSessionReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-observation-revision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let original = try store.upsert(BrowserProfile(name: "Receipt revision")), lease = lock()
        var receipt = ManagedBrowserSessionReceipt(generation: UUID(), lock: lease,
            runtimeVersion: "156.0.8078.12", configuredRoute: .direct, profileRevision: original.revision)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(encoder.encode(lease), to: paths.lockFile(for: original.id))
        let transition = try #require(store.markLaunchedWithReceipt(original.id))
        let launched = transition.recorded
        #expect(try receipt.recordLaunchMetadata(from: original, to: launched))
        let recordedReceipt = receipt
        #expect(try await Task.detached {
            try ManagedSessionLeaseReader.matchesPersistedContext(paths: paths, profile: launched, receipt: recordedReceipt)
        }.value)
        var edited = launched; edited.startURL = "https://example.com/new-context"
        let saved = try store.upsert(edited)
        // Re-reading M from disk must not make receipt N current, with or
        // without a relay transport observation. No live process is spawned.
        #expect(saved.revision != launched.revision)
        let oldFenceWouldAdmit = try await Task.detached {
            try paths.withProcessLockGuard(for: saved.id) {
                try ProfileStore.withPersistedLaunchSnapshot(saved, paths: paths) {
                    try ManagedSessionLeaseReader.read(paths: paths, profileID: saved.id) == recordedReceipt.lock
                }
            }
        }.value
        #expect(oldFenceWouldAdmit)
        #expect(try await Task.detached {
            try !ManagedSessionLeaseReader.matchesPersistedContext(paths: paths, profile: saved, receipt: recordedReceipt)
        }.value)
    }
    @Test func absentLaunchRevisionCannotAuthorizeObservation() {
        var receipt = ManagedBrowserSessionReceipt(generation: UUID(), lock: lock(), runtimeVersion: nil, configuredRoute: .direct)
        #expect(!receipt.matchesProfileRevision(1))
        receipt.observedMetadataRevision = 1
        #expect(!receipt.matchesProfileRevision(1))
    }
    func lock(owner: UUID? = UUID(), manager: pid_t = getpid(), phase: BrowserProcessLockPhase = .running) -> BrowserProcessLock {
        BrowserProcessLock(pid: 123, executablePath: "/synthetic/browser",
                           browserDataPath: "/synthetic/data", createdAt: Date(timeIntervalSince1970: 100),
                           schemaVersion: 2, ownerToken: owner, managerPID: manager, phase: phase)
    }

    @Test func managedReceiptRequiresExactLeaseAndCurrentManager() {
        let original = lock()
        let receipt = ManagedBrowserSessionReceipt(generation: UUID(), lock: original,
                                                  runtimeVersion: "156.0.8078.12", configuredRoute: .httpProxy)
        #expect(receipt.matches(original))
        #expect(!receipt.matches(lock()))
        #expect(!receipt.matches(lock(owner: nil)))
        #expect(!receipt.matches(lock(owner: original.ownerToken, manager: getpid() + 1)))
        #expect(!receipt.matches(lock(owner: original.ownerToken, phase: .starting)))
    }

    @Test func outputNeverContainsPrivateGenerationOrLease() throws {
        let generation = UUID()
        let observation = BrowserSessionObservation(state: .observed, ownership: .thisSession,
            readyForGracefulQuit: true, runtimeVersion: "156.0.8078.12", configuredRoute: .httpProxy,
            sessionGeneration: generation)
        let value = observation.mcpValue
        let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        #expect(!json.contains(generation.uuidString))
        #expect(value["chromiumRoute"] as? String == "notObserved")
        #expect(value["pageObservation"] as? String == "notSupported")
        #expect(Set(value.keys) == ["state", "ownership", "readyForGracefulQuit", "runtimeVersion", "configuredRoute", "chromiumRoute", "pageObservation", "extensionsObservation", "relayTransport"])
        #expect((value["relayTransport"] as? [String: String])?["state"] == "notObserved")
        #expect(Mirror(reflecting: observation).children.isEmpty)
        let absent = BrowserSessionObservation.unavailable(.notOwned).mcpValue
        #expect(absent["readyForGracefulQuit"] is NSNull)
        #expect(absent["runtimeVersion"] is NSNull)
        #expect(absent["configuredRoute"] as? String == "unknown")
    }

    @Test func runtimeVersionRejectsPathOrCredentialText() {
        #expect(ManagedBrowserSessionReceipt.safeRuntimeVersion("156.0.8078.12") == "156.0.8078.12")
        for value in ["156.0.8078", "156.0.8078.12 token", "/synthetic/private", "156..8078.12", "١٥٦.0.8078.12"] {
            #expect(ManagedBrowserSessionReceipt.safeRuntimeVersion(value) == nil)
        }
    }

    @Test func receiptUsesPersistedDatePrecision() throws {
        let original = BrowserProcessLock(pid: 123, executablePath: "/synthetic/browser",
            browserDataPath: "/synthetic/data", createdAt: Date(timeIntervalSince1970: 100.125),
            schemaVersion: 2, ownerToken: UUID(), managerPID: getpid())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(BrowserProcessLock.self, from: encoder.encode(original))
        #expect(persisted.createdAt != original.createdAt)
        let receipt = ManagedBrowserSessionReceipt(generation: UUID(), lock: persisted,
                                                   runtimeVersion: "156.0.8078.12", configuredRoute: .direct)
        #expect(receipt.matches(persisted))
        #expect(!receipt.matches(original))
    }

    @Test func leaseReaderRejectsSymlinkHardlinkAndOversizedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-observation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), profileID = UUID()
        let url = paths.lockFile(for: profileID)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = lock()
        try paths.writePrivateFile(encoder.encode(original), to: url)
        #expect(try ManagedSessionLeaseReader.read(paths: paths, profileID: profileID) == original)
        let hardlink = url.deletingLastPathComponent().appendingPathComponent("synthetic-hardlink")
        #expect(Darwin.link(url.path, hardlink.path) == 0)
        #expect(throws: (any Error).self) { try ManagedSessionLeaseReader.read(paths: paths, profileID: profileID) }
        try FileManager.default.removeItem(at: hardlink)
        try paths.writePrivateFile(Data(repeating: 0, count: 16_385), to: url)
        #expect(throws: (any Error).self) { try ManagedSessionLeaseReader.read(paths: paths, profileID: profileID) }
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("synthetic-target")
        try encoder.encode(original).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: (any Error).self) { try ManagedSessionLeaseReader.read(paths: paths, profileID: profileID) }
    }
}
