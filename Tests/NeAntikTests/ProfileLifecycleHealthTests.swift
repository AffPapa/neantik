import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ProfileLifecycleHealthTests {
    @Test
    func healthyStoppedProfileReportsBoundedLifecycleFacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        try Data(repeating: 7, count: 32).write(
            to: paths.browserDataDirectory(for: profileID)
                .appendingPathComponent("Preferences")
        )
        let launchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let snapshot = try await ProfileLifecycleHealthSnapshot.inspectAsync(
            profileID: profileID,
            lastLaunchedAt: launchedAt,
            processState: .stopped,
            paths: paths
        )

        #expect(snapshot.lock == .clear)
        #expect(snapshot.browserData == .available(bytes: 32, entries: 1))
        #expect(snapshot.recovery == .clear)
        #expect(snapshot.lastLaunchedAt == launchedAt)
    }

    @Test
    func activeLockAndRecoveryMarkerArePresentedWithoutRawValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        try paths.writePrivateFile(Data("private".utf8), to: paths.lockFile(for: profileID))
        try paths.writePrivateFile(
            Data("recovery".utf8),
            to: paths.profileCredentialCleanupMarker(for: profileID)
        )

        let snapshot = ProfileLifecycleHealthSnapshot.inspect(
            profileID: profileID,
            lastLaunchedAt: nil,
            processState: .managed,
            paths: paths
        )

        #expect(snapshot.lock == .managed)
        #expect(snapshot.recovery == .required)
        #expect(snapshot.browserData == .checking)
        #expect(!snapshot.lock.title.contains(profileID.uuidString))
        #expect(!snapshot.recovery.title.contains("recovery"))
    }

    @Test
    func recoveryHistoryDoesNotRequireRecoveryForHealthyProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let archive = paths.profilesRecoveryDirectory
            .appendingPathComponent("profiles-rejected.json")
        try paths.writePrivateFile(Data("preserved".utf8), to: archive)
        for state: BrowserProfileProcessState in [.stopped, .managed, .recoveryRequired] {
            let snapshot = ProfileLifecycleHealthSnapshot.inspect(
                profileID: UUID(), lastLaunchedAt: nil,
                processState: state, paths: paths
            )
            #expect(snapshot.recovery == (state == .recoveryRequired ? .required : .clear))
        }
        #expect(try Data(contentsOf: archive) == Data("preserved".utf8))
    }

    @Test
    func foreignLocksAndUnsafeRecoveryMarkersStillNeedAttention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        try paths.writePrivateFile(Data("lock".utf8), to: paths.lockFile(for: profileID))
        for state: BrowserProfileProcessState in [.stopped, .externalManualOnly, .externalUnverified] {
            let snapshot = ProfileLifecycleHealthSnapshot.inspect(
                profileID: profileID, lastLaunchedAt: nil,
                processState: state, paths: paths
            )
            #expect(snapshot.lock == .active)
        }
        try FileManager.default.createSymbolicLink(
            at: paths.profileCredentialCleanupMarker(for: profileID),
            withDestinationURL: paths.lockFile(for: profileID)
        )
        let snapshot = ProfileLifecycleHealthSnapshot.inspect(
            profileID: profileID, lastLaunchedAt: nil,
            processState: .stopped, paths: paths
        )
        #expect(snapshot.recovery == .unavailable)
    }

    @Test
    func missingBrowserDataIsNotReportedAsHealthy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let snapshot = ProfileLifecycleHealthSnapshot.inspect(
            profileID: UUID(),
            lastLaunchedAt: nil,
            processState: .stopped,
            paths: paths
        )

        #expect(snapshot.browserData == .missing)
        #expect(snapshot.lock == .clear)
    }

    @Test
    func asyncBrowserDataScanRejectsSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        let dataDirectory = paths.browserDataDirectory(for: profileID)
        let external = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(
            to: external.appendingPathComponent("secret")
        )
        try FileManager.default.createSymbolicLink(
            at: dataDirectory.appendingPathComponent("linked"),
            withDestinationURL: external
        )

        let snapshot = try await ProfileLifecycleHealthSnapshot.inspectAsync(
            profileID: profileID,
            lastLaunchedAt: nil,
            processState: .stopped,
            paths: paths
        )

        #expect(snapshot.browserData == .unavailable)
    }

    @Test
    func synchronousLifecycleProjectionDoesNotEnumerateBrowserData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: profileID)
        try Data(repeating: 9, count: 16).write(
            to: paths.browserDataDirectory(for: profileID)
                .appendingPathComponent("Preferences")
        )

        let snapshot = ProfileLifecycleHealthSnapshot.inspect(
            profileID: profileID,
            lastLaunchedAt: nil,
            processState: .stopped,
            paths: paths
        )

        #expect(snapshot.browserData == .checking)
        #expect(snapshot.lock == .clear)
        #expect(snapshot.recovery == .clear)
    }
}
