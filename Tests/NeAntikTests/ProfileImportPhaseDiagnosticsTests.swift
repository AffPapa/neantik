import Foundation
import Testing
@testable import NeAntik

/// Opt-in filesystem diagnostics for a failed large-import budget. This does
/// not replace the ordinary benchmark or relax its acceptance threshold.
@MainActor
struct ProfileImportPhaseDiagnosticsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_PROFILE_IMPORT_PHASE_QA"] == "1"))
    func ownLargeImportPhaseTimings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-import-phase-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        _ = ProfileStore(paths: paths)
        let profiles = (0..<5_000).map { BrowserProfile(name: "Imported \($0)", identity: BrowserIdentity(seed: UInt32($0 + 1))) }
        let folders: [String?] = (0..<5_000).map { "Folder \($0)" }
        let started = ContinuousClock.now
        let result = try await Task.detached {
            try ProfileMetadataImportTransaction.run(paths: paths, requestedProfiles: profiles, folderNames: folders,
                beforeProfilesPersist: { print("Own import phase pre-profile-validation/persist: \(started.duration(to: .now))") },
                beforeOrganizationPersist: { print("Own import phase pre-organization-persist: \(started.duration(to: .now))") })
        }.value
        print("Own import phase transaction-complete: \(started.duration(to: .now))")
        #expect(result.profiles.count == 5_000)
        #expect(result.organization.folders.count == 5_000)
    }
}

@MainActor
struct ProfileImportManagerPhaseDiagnosticsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_PROFILE_IMPORT_PHASE_QA"] == "1"))
    func ownManagerLargeImportPhaseTimings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-import-manager-phase-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profiles = (0..<5_000).map { BrowserProfile(name: "Imported \($0)", identity: BrowserIdentity(seed: UInt32($0 + 1))) }
        let folders: [String?] = (0..<5_000).map { "Folder \($0)" }
        let started = ContinuousClock.now
        let store = ProfileStore(paths: paths, beforeBackgroundImportOrganizationPersist: {
            print("Own manager import phase pre-organization-persist: \(started.duration(to: .now))")
        })
        let saved = try await store.insertImportedProfilesOffMainActor(profiles, folderNames: folders)
        print("Own manager import phase published: \(started.duration(to: .now))")
        #expect(saved.count == 5_000)
        #expect(store.organization.folders.count == 5_000)
    }
}
