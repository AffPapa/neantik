import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayLeaseReceiptTests {
    let profile = UUID(), token = UUID()
    func receipt(pid: pid_t = 123, seconds: Int64 = 100, micros: Int32 = 20, port: UInt16 = 8000,
                 digest: String = String(repeating: "a", count: 64)) -> ProxyRelayLeaseReceipt {
        .init(profileID: profile, sessionGeneration: token, ownerPID: pid,
              ownerStartSeconds: seconds, ownerStartMicroseconds: micros, ownerUID: geteuid(), loopbackPort: port,
              runtimeExecutableSHA256: digest, runtimeFrameworkSHA256: digest, configurationSHA256: digest)
    }
    @Test func cleanupDistinguishesGenerationFromPIDAndIgnoresReparenting() throws {
        let value = receipt(); try value.validate(ownerToken: token)
        let same = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 100, startMicroseconds: 20),
                                                  userID: geteuid(), parentProcessID: 1)
        #expect(!value.ownerIsAbsent(inspect: { _ in same }, isAlive: { _ in true }))
        #expect(!value.ownerIsAbsent(inspect: { _ in nil }, isAlive: { _ in true }))
        #expect(value.ownerIsAbsent(inspect: { _ in nil }, isAlive: { _ in false }))
        let reused = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 101, startMicroseconds: 20),
                                                    userID: geteuid(), parentProcessID: 1)
        #expect(value.ownerIsAbsent(inspect: { _ in reused }, isAlive: { _ in true }))
    }
    @Test func invalidReceiptNeverBecomesAValidRecoveryFence() {
        for value in [receipt(pid: 0), receipt(seconds: 0), receipt(micros: 1_000_000), receipt(port: 0), receipt(digest: "a")] {
            #expect(throws: (any Error).self) { try value.validate(ownerToken: token) }
        }
        #expect(throws: (any Error).self) { try receipt().validate(ownerToken: UUID()) }
    }
    @Test func lockRoundtripAndLegacyDowngradeControls() throws {
        let value = BrowserProcessLock(pid: 0, executablePath: "/synthetic/browser", browserDataPath: "/synthetic/data",
            createdAt: Date(timeIntervalSince1970: 100), schemaVersion: 3, ownerToken: token, managerPID: getpid(), phase: .starting, relay: receipt())
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(value)
        #expect(try decoder.decode(BrowserProcessLock.self, from: data) == value)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("password")); #expect(!json.contains("username")); #expect(!json.contains("upstream"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for schema in [1, 2] {
            object["schemaVersion"] = schema
            #expect(throws: (any Error).self) { try decoder.decode(BrowserProcessLock.self, from: JSONSerialization.data(withJSONObject: object)) }
        }
        object["schemaVersion"] = 3; object["relay"] = ["invalid": true]
        #expect(throws: (any Error).self) { try decoder.decode(BrowserProcessLock.self, from: JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "relay"); object["schemaVersion"] = 2
        #expect(try decoder.decode(BrowserProcessLock.self, from: JSONSerialization.data(withJSONObject: object)).relay == nil)
    }
    @Test func pendingFenceRetainsUninspectableLiveChildAndValidatesSchema() throws {
        let unknown = ProxyRelayPendingOwnerFence(profileID: profile, sessionGeneration: token, ownerPID: 123, identity: nil)
        try unknown.validate(ownerToken: token)
        #expect(!unknown.ownerIsAbsent(inspect: { _ in nil }, isAlive: { _ in true }))
        #expect(unknown.ownerIsAbsent(inspect: { _ in nil }, isAlive: { _ in false }))
        let generation = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 100, startMicroseconds: 2), userID: geteuid(), parentProcessID: 1)
        let known = ProxyRelayPendingOwnerFence(profileID: profile, sessionGeneration: token, ownerPID: 123, identity: generation)
        #expect(!known.ownerIsAbsent(inspect: { _ in generation }, isAlive: { _ in true }))
        #expect(!known.ownerIsAbsent(inspect: { _ in nil }, isAlive: { _ in true }))
        let reused = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 101, startMicroseconds: 2), userID: geteuid(), parentProcessID: 1)
        #expect(known.ownerIsAbsent(inspect: { _ in reused }, isAlive: { _ in true }))
        #expect(throws: (any Error).self) { try unknown.validate(ownerToken: UUID()) }
        let value = BrowserProcessLock(pid: 0, executablePath: "/synthetic/browser", browserDataPath: "/synthetic/data", createdAt: Date(),
            schemaVersion: 3, ownerToken: token, managerPID: getpid(), phase: .starting, pendingRelayOwner: unknown)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        #expect(try decoder.decode(BrowserProcessLock.self, from: encoder.encode(value)) == value)
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
        for key in ["schemaVersion", "pid"] {
            var changed = object; changed[key] = key == "pid" ? 123 : 2
            #expect(throws: (any Error).self) { try decoder.decode(BrowserProcessLock.self, from: JSONSerialization.data(withJSONObject: changed)) }
        }
        object["relay"] = try JSONSerialization.jsonObject(with: encoder.encode(receipt()))
        #expect(throws: (any Error).self) { try decoder.decode(BrowserProcessLock.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @MainActor @Test(arguments: [true, false])
    func pendingFenceSurvivesRestartUntilOwnerAbsent(alive: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), browser = BrowserProfile(name: "Pending relay recovery fixture")
        let fence = ProxyRelayPendingOwnerFence(profileID: browser.id, sessionGeneration: token, ownerPID: 123, identity: nil)
        let provisional = BrowserProcessLock(pid: 0, executablePath: "/synthetic/browser", browserDataPath: paths.browserDataDirectory(for: browser.id).standardizedFileURL.path,
            createdAt: Date(timeIntervalSince1970: 100), schemaVersion: 3, ownerToken: token, managerPID: 456, phase: .starting)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(encoder.encode(provisional), to: paths.lockFile(for: browser.id))
        try fence.persist(paths: paths, expected: provisional)
        let saved = try Data(contentsOf: paths.lockFile(for: browser.id))
        #expect(throws: (any Error).self) { try fence.persist(paths: paths, expected: provisional) }
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { pid in pid == 123 && alive }, browserDataProcessInspector: { _ in .absent })
        manager.reconcile(profiles: [browser])
        if alive {
            #expect(manager.runningProfileIDs.contains(browser.id))
            #expect(try Data(contentsOf: paths.lockFile(for: browser.id)) == saved)
        } else {
            #expect(!manager.runningProfileIDs.contains(browser.id))
            #expect(try paths.privateFileEntryKind(paths.lockFile(for: browser.id)) == .missing)
        }
    }

    @MainActor @Test(arguments: [true, false], [true, false])
    func failedDurableFenceStillRetainsUnconfirmedChildDuringReconcile(alive: Bool, corrupt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), browser = BrowserProfile(name: "Injected pending write failure")
        let fence = ProxyRelayPendingOwnerFence(profileID: browser.id, sessionGeneration: token, ownerPID: 123, identity: nil)
        let provisional = BrowserProcessLock(pid: 0, executablePath: "/synthetic/browser", browserDataPath: paths.browserDataDirectory(for: browser.id).standardizedFileURL.path,
            createdAt: Date(timeIntervalSince1970: 100), schemaVersion: 3, ownerToken: token, managerPID: 456, phase: .starting)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(provisional)
        try paths.writePrivateFile(original, to: paths.lockFile(for: browser.id))
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { pid in pid == 123 && alive }, browserDataProcessInspector: { _ in .absent }, potentialRelayOwnerInspector: { .absent })
        defer { manager.suspendPassiveObservations() }
        let acquired = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let guardTask = Task.detached {
            try paths.withProcessLockGuard(for: browser.id) {
                acquired.signal(); _ = release.wait(timeout: .now() + 5)
            }
        }
        // Wait on a detached executor, never block the manager actor.
        let ready = await Task.detached { acquired.wait(timeout: .now() + 3) == .success }.value
        try #require(ready)
        await manager.retainUnconfirmedRelayStartup(fence, expectedLease: provisional)
        release.signal(); try await guardTask.value
        #expect(try Data(contentsOf: paths.lockFile(for: browser.id)) == original)
        let observed = corrupt ? Data("{not-json".utf8) : original
        if corrupt { try paths.writePrivateFile(observed, to: paths.lockFile(for: browser.id)) }
        manager.reconcile(profiles: [browser])
        if alive {
            #expect(manager.runningProfileIDs.contains(browser.id))
            #expect(try Data(contentsOf: paths.lockFile(for: browser.id)) == observed)
        } else {
            #expect(!manager.runningProfileIDs.contains(browser.id))
            #expect(try paths.privateFileEntryKind(paths.lockFile(for: browser.id)) == .missing)
        }
        #expect(ProxyRelayOwnerClient.Failure.cleanupUnconfirmed(fence).requiresCleanupRecovery)
        #expect(ProxyRelayOwnerClient.Failure.cleanupUnconfirmed(fence).pendingFence == fence)
        #expect(!ProxyRelayOwnerClient.Failure.invalidReply.requiresCleanupRecovery)
    }

    @MainActor @Test(arguments: [BrowserDataProcessInspection.found, .unknown, .absent])
    func truncatedLeaseRequiresIndependentRelayAbsence(evidence: BrowserDataProcessInspection) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), browser = BrowserProfile(name: "Truncated relay recovery")
        try paths.prepareProfileDirectories(for: browser.id)
        let truncated = Data("{\"schemaVersion\":3,\"relay\":".utf8)
        try paths.writePrivateFile(truncated, to: paths.lockFile(for: browser.id))
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false }, browserDataProcessInspector: { _ in .absent },
            potentialRelayOwnerInspector: { evidence })
        defer { manager.suspendPassiveObservations() }
        manager.reconcile(profiles: [browser])
        if evidence == .absent {
            #expect(manager.processState(for: browser.id) == .stopped)
            #expect(try paths.privateFileEntryKind(paths.lockFile(for: browser.id)) == .missing)
        } else {
            #expect(manager.processState(for: browser.id) == .recoveryRequired)
            #expect(try Data(contentsOf: paths.lockFile(for: browser.id)) == truncated)
        }
    }

}
