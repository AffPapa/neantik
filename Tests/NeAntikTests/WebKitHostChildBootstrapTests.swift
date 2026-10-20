import Foundation
import Testing
@testable import NeAntik

@MainActor
struct WebKitHostChildBootstrapTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-webkit-host-bootstrap-" + UUID().uuidString,
                                    isDirectory: true)
    }

    private func session(_ profile: BrowserProfile, root: URL,
                         generation: UUID = UUID(), revision: UInt64? = nil,
                         runtimeSHA256: String = String(repeating: "a", count: 64)) -> WebKitHostIPC.Session {
        .init(profileID: profile.id, revision: revision ?? profile.revision,
              generation: generation, dataRoot: root.standardizedFileURL.path,
              runtimeSHA256: runtimeSHA256)
    }

    private func reserve(_ session: WebKitHostIPC.Session, paths: AppPaths) throws {
        let sessionGuard = try paths.acquireWebKitSessionGuard(for: session.profileID)
        let metadataGuard = try paths.acquireWebKitMetadataGuard(for: session.profileID)
        defer { metadataGuard.release(); sessionGuard.release() }
        _ = try WebKitHostLeaseReservation.persist(session: session,
            childPID: getpid(),
            childExecutablePath: Bundle.main.executablePath!,
            paths: paths,
            sessionGuard: sessionGuard,
            metadataGuard: metadataGuard,
            managerPID: getppid())
    }

    @Test func reservationFailuresHaveActionableLocalizedDescriptions() {
        let failures: [WebKitHostLeaseReservation.Failure] = [
            .invalidSession, .dataRootMismatch, .invalidProcessIdentity,
            .invalidExecutablePath, .guardNotHeld, .reservationExists,
            .reservationMismatch, .cleanupUnconfirmed
        ]
        let descriptions = failures.compactMap(\.errorDescription)
        #expect(descriptions.count == failures.count)
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        #expect(Set(descriptions).count == failures.count)
    }

    @Test func executablePathValidationPreservesPrivateTmpAliasAndRejectsTraversal() {
        #expect(WebKitHostLeaseReservation.isCanonicalExecutablePath(
            "/private/tmp/NeAntik QA.app/Contents/MacOS/NeAntikWebKitHost"))
        #expect(WebKitHostLeaseReservation.isCanonicalExecutablePath(
            "/tmp/NeAntik QA.app/Contents/MacOS/NeAntikWebKitHost"))
        #expect(!WebKitHostLeaseReservation.isCanonicalExecutablePath(
            "/private/tmp/../Applications/NeAntikWebKitHost"))
        #expect(!WebKitHostLeaseReservation.isCanonicalExecutablePath(
            "/private/tmp//NeAntikWebKitHost"))
        #expect(!WebKitHostLeaseReservation.isCanonicalExecutablePath(
            "relative/NeAntikWebKitHost"))
    }

    @Test func childStartupDiagnosticsAcceptOnlyBoundedSafeCodes() {
        #expect(WebKitHostClient.childStartupDiagnosticCode(
            Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=runtime-missingRuntimeImage\n".utf8)) ==
            "runtime-missingRuntimeImage")
        #expect(WebKitHostClient.childStartupDiagnosticCode(
            Data("/private/tmp/secret-profile\n".utf8)) == nil)
        #expect(WebKitHostClient.childStartupDiagnosticCode(
            Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=runtime bad\n".utf8)) == nil)
        #expect(WebKitHostClient.childStartupDiagnosticCode(Data(repeating: 65, count: 257)) == nil)
    }

    @Test func childStartupStageUsesLastBoundedMarkerOnly() {
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=identity-verified\nNEANTIK_WEBKIT_STARTUP_STAGE stage=runtime-attested\n".utf8)) == "runtime-attested")
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=/private/tmp/profile\n".utf8)) == nil)
        #expect(WebKitHostClient.childStartupStage(Data(repeating: 65, count: 257)) == nil)
    }

    @Test func reservationReportsTheExactInvalidLaunchInput() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profileID = UUID()
        let sessionGuard = try paths.acquireWebKitSessionGuard(for: profileID)
        let metadataGuard = try paths.acquireWebKitMetadataGuard(for: profileID)
        defer { metadataGuard.release(); sessionGuard.release() }
        let good = WebKitHostIPC.Session(profileID: profileID, revision: 1,
            generation: UUID(), dataRoot: root.standardizedFileURL.path,
            runtimeSHA256: String(repeating: "a", count: 64))
        let child = getpid() + 1
        func persist(_ value: WebKitHostIPC.Session, childPID: pid_t = child,
                     executable: String = "/tmp/NeAntikWebKitHost") throws {
            _ = try WebKitHostLeaseReservation.persist(session: value,
                childPID: childPID, childExecutablePath: executable,
                paths: paths, sessionGuard: sessionGuard,
                metadataGuard: metadataGuard, managerPID: getpid())
        }

        #expect(throws: WebKitHostLeaseReservation.Failure.invalidSession) {
            try persist(.init(profileID: profileID, revision: 0,
                generation: good.generation, dataRoot: good.dataRoot,
                runtimeSHA256: good.runtimeSHA256))
        }
        #expect(throws: WebKitHostLeaseReservation.Failure.dataRootMismatch) {
            try persist(.init(profileID: profileID, revision: 1,
                generation: good.generation,
                dataRoot: root.appendingPathComponent("other").path,
                runtimeSHA256: good.runtimeSHA256))
        }
        #expect(throws: WebKitHostLeaseReservation.Failure.invalidProcessIdentity) {
            try persist(good, childPID: getpid())
        }
        #expect(throws: WebKitHostLeaseReservation.Failure.invalidExecutablePath) {
            try persist(good, executable: "relative-helper")
        }
    }

    @Test func childRevalidatesExactIsolatedProfileAndOwnsBothGuards() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = try ProfileStore(paths: paths).upsert(BrowserProfile(
            name: "Isolated QA", startURL: "about:blank", engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1))

        let launch = session(profile, root: root)
        try reserve(launch, paths: paths)
        let child = try WebKitHostChildBootstrap.acquireForTesting(
            session: launch,
            expectedRuntimeSHA256: String(repeating: "a", count: 64))
        #expect(child.profile.id == profile.id)
        #expect(child.profile.revision == profile.revision)
        #expect(throws: ProfileProcessBusyError.self) {
            try paths.acquireWebKitSessionGuard(for: profile.id)
        }
        #expect(throws: ProfileProcessBusyError.self) {
            try paths.acquireWebKitMetadataGuard(for: profile.id)
        }
        child.releaseAfterClose()
        let sessionLease = try paths.acquireWebKitSessionGuard(for: profile.id)
        let metadataLease = try paths.acquireWebKitMetadataGuard(for: profile.id)
        sessionLease.release(); metadataLease.release()
    }

    @Test func childRejectsSystemGenerationAndStaleRevision() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = try ProfileStore(paths: paths).upsert(BrowserProfile(
            name: "System WebKit", startURL: "about:blank", engine: .webkit))
        let current = session(profile, root: root)
        try reserve(current, paths: paths)
        let stale = session(profile, root: root, generation: current.generation,
                            revision: profile.revision + 1)
        #expect(throws: WebKitHostChildBootstrap.Failure.profileMismatch) {
            try WebKitHostChildBootstrap.acquireForTesting(session: current,
                expectedRuntimeSHA256: String(repeating: "a", count: 64))
        }
        #expect(throws: WebKitHostChildBootstrap.Failure.profileMismatch) {
            try WebKitHostChildBootstrap.acquireForTesting(session: stale,
                expectedRuntimeSHA256: String(repeating: "a", count: 64))
        }
    }

    @Test func childRejectsDeletionTombstoneAndReleasesBothGuards() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = try ProfileStore(paths: paths).upsert(BrowserProfile(
            name: "Deleting isolated profile", startURL: "about:blank", engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1))
        let launch = session(profile, root: root)
        try reserve(launch, paths: paths)
        try paths.createPrivateFileExclusively(
            Data("deleted-v1".utf8),
            at: paths.profileDeletionTombstone(for: profile.id)
        )

        #expect(throws: WebKitHostChildBootstrap.Failure.profileUnavailable) {
            try WebKitHostChildBootstrap.acquireForTesting(
                session: launch,
                expectedRuntimeSHA256: String(repeating: "a", count: 64))
        }

        let sessionLease = try paths.acquireWebKitSessionGuard(for: profile.id)
        let metadataLease = try paths.acquireWebKitMetadataGuard(for: profile.id)
        sessionLease.release()
        metadataLease.release()
    }

    @Test func childRequiresExactManagerReservationBeforeReadingProfile() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = try ProfileStore(paths: paths).upsert(BrowserProfile(
            name: "Unreserved isolated profile", startURL: "about:blank", engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1))
        let launch = session(profile, root: root)
        #expect(throws: WebKitHostChildBootstrap.Failure.reservationMismatch) {
            try WebKitHostChildBootstrap.acquireForTesting(session: launch,
                expectedRuntimeSHA256: String(repeating: "a", count: 64))
        }

        try reserve(launch, paths: paths)
        let changedGeneration = session(profile, root: root, generation: UUID())
        #expect(throws: WebKitHostChildBootstrap.Failure.reservationMismatch) {
            try WebKitHostChildBootstrap.acquireForTesting(session: changedGeneration,
                expectedRuntimeSHA256: String(repeating: "a", count: 64))
        }
        let sessionGuard = try paths.acquireWebKitSessionGuard(for: profile.id)
        sessionGuard.release()
    }

    @Test func reservationRemovalWaitsForChildAndRemovesOnlyOwnedLease() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = try ProfileStore(paths: paths).upsert(BrowserProfile(
            name: "Reserved isolated profile", startURL: "about:blank", engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1))
        let launch = session(profile, root: root)
        let sessionGuard = try paths.acquireWebKitSessionGuard(for: profile.id)
        let metadataGuard = try paths.acquireWebKitMetadataGuard(for: profile.id)
        let reservation = try WebKitHostLeaseReservation.persist(session: launch,
            childPID: getpid(), childExecutablePath: Bundle.main.executablePath!,
            paths: paths, sessionGuard: sessionGuard, metadataGuard: metadataGuard,
            managerPID: getppid())
        metadataGuard.release(); sessionGuard.release()

        #expect(throws: WebKitHostLeaseReservation.Failure.cleanupUnconfirmed) {
            try reservation.remove(paths: paths, childIsGone: { false })
        }
        #expect(try paths.privateFileEntryKind(paths.lockFile(for: profile.id)) == .regular)
        try reservation.remove(paths: paths, childIsGone: { true })
        #expect(try paths.privateFileEntryKind(paths.lockFile(for: profile.id)) == .missing)
    }

    @Test func childRejectsRuntimePinMismatchBeforeOpeningProfile() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = try ProfileStore(paths: paths).upsert(BrowserProfile(
            name: "Isolated QA", startURL: "about:blank", engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1))
        let launch = session(profile, root: root)
        #expect(throws: WebKitHostChildBootstrap.Failure.runtimeMismatch) {
            try WebKitHostChildBootstrap.acquireForTesting(session: launch,
                expectedRuntimeSHA256: String(repeating: "b", count: 64))
        }
        // Pin mismatch is rejected before touching either profile guard.
        let lease = try paths.acquireWebKitSessionGuard(for: profile.id)
        lease.release()
    }

    @Test func productionBootstrapRejectsUnattestedTestRunnerBeforeOpeningProfile() {
        let session = WebKitHostIPC.Session(
            profileID: UUID(), revision: 1, generation: UUID(),
            dataRoot: "/private/tmp/does-not-need-to-exist",
            runtimeSHA256: String(repeating: "a", count: 64))
        #expect(throws: WebKitHostCodeIdentity.Failure.codeIdentityMismatch) {
            try WebKitHostChildBootstrap.acquire(
                session: session,
                expectedRuntimeSHA256: String(repeating: "a", count: 64))
        }
    }
}
