import Foundation
import Testing
@testable import NeAntik

struct EphemeralProfileStorageTests {
    struct Refused: Error {}
    private func fixture() throws -> (AppPaths, BrowserProfile, OwnedProfileDirectory) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-ephemeral-unit-" + UUID().uuidString)
        let paths = AppPaths(rootDirectory: root); try paths.prepareBaseDirectories()
        var policy = BrowserPrivacyPolicy.strict; policy.retention = .ephemeral
        let profile = BrowserProfile(name: "Own disposable session", privacyPolicy: policy)
        let owned = try OwnedProfileDirectory(paths: paths, profileID: profile.id)
        try owned.prepareBrowserData(for: profile)
        return (paths, profile, owned)
    }

    @Test func cleanupAndNextLaunchDoNotReusePreviousSessionState() throws {
        let (paths, profile, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: profile)
        let data = paths.browserDataDirectory(for: profile.id)
        try Data("synthetic-cookie".utf8).write(to: data.appendingPathComponent("state"))
        #expect(try EphemeralProfileStorage.pending(paths: paths, profile: profile))
        try EphemeralProfileStorage.clear(paths: paths, profile: profile, validateAuthority: {}, requireAbsent: { _ in })
        #expect(!FileManager.default.fileExists(atPath: data.path))
        #expect(try !EphemeralProfileStorage.pending(paths: paths, profile: profile))
        // Common launch preparation may recreate an empty canonical container.
        try paths.prepareProfileDirectories(for: profile.id)
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: profile)
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path).isEmpty)
    }

    @Test func unknownInventoryRefusesBeforeDetachingOrDeleting() throws {
        let (paths, profile, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: profile)
        let file = paths.browserDataDirectory(for: profile.id).appendingPathComponent("state")
        try Data("preserve".utf8).write(to: file)
        #expect(throws: Refused.self) {
            try EphemeralProfileStorage.clear(paths: paths, profile: profile, validateAuthority: {}, requireAbsent: { _ in throw Refused() })
        }
        #expect(try Data(contentsOf: file) == Data("preserve".utf8))
    }

    @Test func interruptedDeletionResumesOnlyPinnedRetiredRoot() throws {
        let (paths, profile, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: profile)
        try Data("session".utf8).write(to: paths.browserDataDirectory(for: profile.id).appendingPathComponent("state"))
        #expect(throws: Refused.self) {
            try EphemeralProfileStorage.clear(paths: paths, profile: profile, validateAuthority: {}, requireAbsent: { _ in }, beforeUnlink: { throw Refused() })
        }
        #expect(try EphemeralProfileStorage.pending(paths: paths, profile: profile))
        try EphemeralProfileStorage.clear(paths: paths, profile: profile, validateAuthority: {}, requireAbsent: { _ in })
        #expect(try !EphemeralProfileStorage.pending(paths: paths, profile: profile))
    }

    @Test func replacedBrowserDataIsNeverAdoptedOrDeleted() throws {
        let (paths, profile, owner) = try fixture(); _ = owner
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: profile)
        let data = paths.browserDataDirectory(for: profile.id), held = paths.profileDirectory(for: profile.id).appendingPathComponent("held")
        try FileManager.default.moveItem(at: data, to: held)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let foreign = data.appendingPathComponent("foreign")
        try Data("foreign".utf8).write(to: foreign)
        #expect(throws: (any Error).self) {
            try EphemeralProfileStorage.clear(paths: paths, profile: profile, validateAuthority: {}, requireAbsent: { _ in })
        }
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        #expect(FileManager.default.fileExists(atPath: held.path))
    }
}


@MainActor
@Suite(.serialized)
struct EphemeralProfileLifecycleTests {
    private func fixture(available: Bool) throws -> (AppPaths, BrowserProfile, BrowserProcessManager) {
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-ephemeral-manager-" + UUID().uuidString))
        let store = ProfileStore(paths: paths)
        var policy = BrowserPrivacyPolicy.strict; policy.retention = .ephemeral
        let profile = try store.upsert(BrowserProfile(name: "Own disposable recovery", privacyPolicy: policy))
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: profile)
        try Data("private synthetic state".utf8).write(to: paths.browserDataDirectory(for: profile.id).appendingPathComponent("state"))
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated },
            processLivenessValidator: { _ in false }, processInventoryProvider: {
                BrowserProcessInventory(processes: [:], available: available)
            }, potentialRelayOwnerInspector: { .absent }, validatesPersistedProfiles: true)
        return (paths, profile, manager)
    }

    private func awaitCleanup(_ manager: BrowserProcessManager, profile: BrowserProfile) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while manager.ephemeralCleanupPending.contains(profile.id) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!manager.ephemeralCleanupPending.contains(profile.id))
    }

    @Test func startupRecoversIssuedSessionAndRepeatedReconcileDoesNotReuseData() async throws {
        let (paths, profile, manager) = try fixture(available: true)
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        manager.reconcile(profiles: [profile])
        #expect(manager.processState(for: profile.id) == .closing)
        #expect(manager.hasWorkPreventingUpdate)
        try await awaitCleanup(manager, profile: profile)
        #expect(!manager.ephemeralCleanupFailures.contains(profile.id))
        #expect(try !EphemeralProfileStorage.pending(paths: paths, profile: profile))
        #expect(!FileManager.default.fileExists(atPath: paths.browserDataDirectory(for: profile.id).path))
        manager.reconcile(profiles: [profile])
        #expect(!manager.ephemeralCleanupPending.contains(profile.id))
    }

    @Test func unavailableInventoryPreservesDataAndExplicitRetryIsSingleFlight() async throws {
        let (paths, profile, manager) = try fixture(available: false)
        defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        manager.reconcile(profiles: [profile]); try await awaitCleanup(manager, profile: profile)
        #expect(manager.ephemeralCleanupFailures.contains(profile.id))
        #expect(manager.processState(for: profile.id) == .recoveryRequired)
        #expect(manager.hasWorkPreventingUpdate)
        manager.reconcile(profiles: [profile])
        #expect(!manager.ephemeralCleanupPending.contains(profile.id))
        manager.retryEphemeralCleanup(profile: profile)
        manager.retryEphemeralCleanup(profile: profile)
        try await awaitCleanup(manager, profile: profile)
        #expect(manager.ephemeralCleanupFailures.contains(profile.id))
        #expect(try Data(contentsOf: paths.browserDataDirectory(for: profile.id).appendingPathComponent("state")) == Data("private synthetic state".utf8))
    }
}
