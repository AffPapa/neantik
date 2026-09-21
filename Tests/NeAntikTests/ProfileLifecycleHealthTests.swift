import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ProfileLifecycleHealthTests {
    @Test
    func healthyStoppedProfileReportsBoundedLifecycleFacts() throws {
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

        let snapshot = ProfileLifecycleHealthSnapshot.inspect(
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

        #expect(snapshot.lock == .active)
        #expect(snapshot.recovery == .required)
        #expect(snapshot.browserData != .unavailable)
        #expect(!snapshot.lock.title.contains(profileID.uuidString))
        #expect(!snapshot.recovery.title.contains("recovery"))
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
}
