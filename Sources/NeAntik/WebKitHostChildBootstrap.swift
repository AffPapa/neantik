import Darwin
import Foundation

/// Child-owned profile context. Call only after authenticating the parent and
/// the runtime bundle; holding this value keeps both profile guards alive for
/// the full WebKit window lifetime.
@MainActor
final class WebKitHostChildBootstrap {
    enum Failure: Error, Equatable {
        case invalidRoot
        case profileUnavailable
        case profileMismatch
        case runtimeMismatch
        case reservationMismatch
    }

    let session: WebKitHostIPC.Session
    let paths: AppPaths
    let profile: BrowserProfile
    let reservation: WebKitHostLeaseReservation
    private var sessionLease: PrivateFileGuardLease?
    private var metadataLease: PrivateFileGuardLease?

    /// The browser receives these exact child-owned leases. It releases them
    /// only after downloads and session writes settle; the bootstrap object
    /// remains retained by the child runtime as an additional lifetime fence.
    func browserGuardLeases() throws -> (session: PrivateFileGuardLease, metadata: PrivateFileGuardLease) {
        guard let sessionLease, let metadataLease else { throw Failure.profileUnavailable }
        return (sessionLease, metadataLease)
    }

    private init(session: WebKitHostIPC.Session, paths: AppPaths,
                 profile: BrowserProfile, reservation: WebKitHostLeaseReservation,
                 sessionLease: PrivateFileGuardLease,
                 metadataLease: PrivateFileGuardLease) {
        self.session = session
        self.paths = paths
        self.profile = profile
        self.reservation = reservation
        self.sessionLease = sessionLease
        self.metadataLease = metadataLease
    }

    /// Re-open only the exact immutable isolatedV1 profile revision named by
    /// the authenticated parent. The child acquires its own guards; no lock
    /// descriptor is transferred from the manager process.
    static func acquire(session: WebKitHostIPC.Session,
                        expectedRuntimeSHA256: String) throws -> WebKitHostChildBootstrap {
        // Keep the security boundary at the data-opening API itself. A future
        // caller cannot accidentally acquire profile locks before proving that
        // this exact helper was launched by the signed NeAntik manager.
        try WebKitHostCodeIdentity.verifyCurrentHostAndParent(
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            expectedParentPID: getppid())
        return try acquireAfterIdentityCheck(session: session,
                                             expectedRuntimeSHA256: expectedRuntimeSHA256)
    }

    /// Fixture-only entry point. It exercises profile revision and lock
    /// ownership without pretending a test runner is the signed production
    /// helper. Never use this from app or release code.
    #if DEBUG
    static func acquireForTesting(session: WebKitHostIPC.Session,
                                  expectedRuntimeSHA256: String) throws -> WebKitHostChildBootstrap {
        try acquireAfterIdentityCheck(session: session,
                                      expectedRuntimeSHA256: expectedRuntimeSHA256)
    }
    #endif

    private static func acquireAfterIdentityCheck(session: WebKitHostIPC.Session,
                                                   expectedRuntimeSHA256: String) throws -> WebKitHostChildBootstrap {
        guard session.isValid(), session.runtimeSHA256 == expectedRuntimeSHA256,
              expectedRuntimeSHA256.utf8.count == 64,
              expectedRuntimeSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw Failure.runtimeMismatch }

        let root = URL(fileURLWithPath: session.dataRoot, isDirectory: true)
        let paths = AppPaths(rootDirectory: root)
        guard paths.rootDirectory.standardizedFileURL.path == session.dataRoot else {
            throw Failure.invalidRoot
        }
        try paths.validatePrivateDirectory(root)

        let sessionLease: PrivateFileGuardLease
        do { sessionLease = try paths.acquireWebKitSessionGuard(for: session.profileID) }
        catch { throw Failure.profileUnavailable }
        do {
            let metadataLease = try paths.acquireWebKitMetadataGuard(for: session.profileID)
            do {
                let reservation: WebKitHostLeaseReservation
                do { reservation = try WebKitHostLeaseReservation.validateChild(session: session, paths: paths) }
                catch { throw Failure.reservationMismatch }
                // Match the manager-side launch fence before reading metadata.
                // A tombstone is authoritative even if stale metadata still
                // contains the profile after an interrupted deletion.
                guard try paths.privateFileEntryKind(
                    paths.profileDeletionTombstone(for: session.profileID)
                ) == .missing else {
                    throw Failure.profileUnavailable
                }
                let store = ProfileStore(paths: paths, readOnlyMetadata: true)
                guard let profile = store.profile(withID: session.profileID) else {
                    throw Failure.profileUnavailable
                }
                guard profile.engine == .webkit,
                      profile.webKitRuntimeGeneration == .isolatedV1,
                      profile.revision == session.revision,
                      !profile.isArchived else { throw Failure.profileMismatch }
                try WebKitProfilePolicy.validateConfiguration(profile)
                try ProfileStore.withValidatedLaunchSnapshot(profile, paths: paths) {}
                return WebKitHostChildBootstrap(session: session, paths: paths,
                    profile: profile, reservation: reservation,
                    sessionLease: sessionLease,
                    metadataLease: metadataLease)
            } catch {
                metadataLease.release()
                throw error
            }
        } catch {
            sessionLease.release()
            throw error
        }
    }

    /// Release only after WebKit downloads and session persistence have settled.
    func releaseAfterClose() {
        metadataLease?.release(); metadataLease = nil
        sessionLease?.release(); sessionLease = nil
    }
}
