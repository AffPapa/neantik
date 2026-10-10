import Darwin
import Foundation
import Testing
@testable import NeAntik

struct BrowserSessionObservationTests {
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
        #expect(Set(value.keys) == ["state", "ownership", "readyForGracefulQuit", "runtimeVersion", "configuredRoute", "chromiumRoute", "pageObservation", "extensionsObservation"])
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
