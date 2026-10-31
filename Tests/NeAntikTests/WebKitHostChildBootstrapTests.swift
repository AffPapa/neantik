import Foundation
import Testing
@testable import NeAntik

@MainActor
struct WebKitHostChildBootstrapTests {
    @Test func managerLeaseWireFormatDecodesInStandaloneHost() throws {
        let token = UUID()
        let lock = BrowserProcessLock(
            pid: 23145,
            executablePath: "/private/tmp/NeAntik.app/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/MacOS/NeAntikWebKitHost",
            browserDataPath: "/private/tmp/qa/Profiles/\(token.uuidString)/BrowserData",
            createdAt: Date(timeIntervalSince1970: 1_234_567_890),
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: token, managerPID: 23144, phase: .running)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(lock)
        let record = try JSONDecoder().decode(WebKitHostReservationRecord.self, from: encoded)
        #expect(record.schemaVersion == BrowserProcessLock.currentSchemaVersion)
        #expect(record.ownerToken == token)
        #expect(record.managerPID == 23144)
        #expect(record.pid == 23145)
        #expect(record.phase == "running")
        #expect(record.executablePath == lock.executablePath)
        #expect(record.browserDataPath == lock.browserDataPath)
    }

    @Test func hostLeaseAcceptsOnlyTemporaryDirectoryAlias() {
        let suffix = "NeAntik.app/Contents/MacOS/NeAntikWebKitHost"
        #expect(WebKitHostReservationRecord.matchesExecutablePath(
            "/private/tmp/\(suffix)", "/tmp/\(suffix)"))
        #expect(WebKitHostReservationRecord.matchesExecutablePath(
            "/Applications/\(suffix)", "/Applications/\(suffix)"))
        #expect(!WebKitHostReservationRecord.matchesExecutablePath(
            "/private/tmp/\(suffix)", "/tmp/other/\(suffix)"))
        #expect(!WebKitHostReservationRecord.matchesExecutablePath(
            "/private/tmp/\(suffix)", "/private/tmp/../tmp/\(suffix)"))
        #expect(!WebKitHostReservationRecord.matchesExecutablePath(
            "/Applications/\(suffix)", "/tmp/\(suffix)"))
    }

    @Test func leaseFailureTokensStayBoundedAndRejectUnknownValues() {
        let known = Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=lease-executableMismatch\n".utf8)
        let unknown = Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=lease-secret-path\n".utf8)
        var accepted = WebKitStartupDiagnosticCapture.Tokens()
        accepted.append(known)
        #expect(WebKitHostClient.childStartupDiagnosticCode(accepted.snapshot) == "lease-executableMismatch")
        var rejected = WebKitStartupDiagnosticCapture.Tokens()
        rejected.append(unknown)
        #expect(rejected.snapshot.isEmpty)
    }

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
        #expect(WebKitHostClient.childStartupDiagnosticCode(Data(repeating: 65, count: 1025)) == nil)
    }

    @Test func childStartupStageUsesLastBoundedMarkerOnly() {
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=identity-verified\nNEANTIK_WEBKIT_STARTUP_STAGE stage=runtime-attested\n".utf8)) == "runtime-attested")
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=visible-runtime-attested\n".utf8)) == "visible-runtime-attested")
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-tls-scope-created\n".utf8)) == "qa-tls-scope-created")
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-tls-host-denied\n".utf8)) == "qa-tls-host-denied")
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-tls-root-denied\n".utf8)) == "qa-tls-root-denied")
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-tls-scope-install-rejected\n".utf8)) ==
            "qa-tls-scope-install-rejected")
        #expect(WebKitHostClient.childStartupStage(Data(
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=/private/tmp/profile\n".utf8)) == nil)
        #expect(WebKitHostClient.childStartupStage(Data(repeating: 65, count: 1025)) == nil)
    }

    @Test func qaNavigationStageSurvivesLaterCloseAndRejectsUntrustedText() {
        var capture = WebKitStartupDiagnosticCapture.Tokens()
        capture.append(Data((
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-nav-started\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-nav-failed-url\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-nav-url-code-m1003\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=close-callback\n").utf8))
        #expect(WebKitHostClient.childQANavigationStage(capture.snapshot) == "qa-nav-url-code-m1003")
        #expect(WebKitHostClient.childStartupStage(capture.snapshot) == "close-callback")
        #expect(WebKitHostClient.childQANavigationStage(Data(
            "NEANTIK_WEBKIT_QA_NAV stage=/private/tmp/secret\n".utf8)) == nil)
        #expect(WebKitHostClient.childQANavigationStage(Data(
            "NEANTIK_WEBKIT_QA_NAV stage=qa-nav-url-code-m999999\n".utf8)) == nil)
        #expect(WebKitHostClient.childQANavigationStage(Data(
            "NEANTIK_WEBKIT_QA_NAV stage=qa-nav-other-code-m42\n".utf8)) == "qa-nav-other-code-m42")
        #expect(WebKitHostClient.childQANavigationStage(Data(
            "NEANTIK_WEBKIT_QA_NAV stage=qa-nav-other-code-m999999\n".utf8)) == nil)
    }

    @Test func qaWindowAndFinishedNavigationStagesAreBounded() {
        var capture = WebKitStartupDiagnosticCapture.Tokens()
        capture.append(Data((
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-window-visible\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-nav-finished\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-nav-sentinel\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=close-callback\n").utf8))
        #expect(WebKitHostClient.childQAWindowStage(capture.snapshot) == "qa-window-visible")
        #expect(WebKitHostClient.childQANavigationStage(capture.snapshot) == "qa-nav-sentinel")
        #expect(WebKitHostClient.childQAWindowStage(Data(
            "NEANTIK_WEBKIT_QA_WINDOW stage=visible-with-url\n".utf8)) == nil)
    }

    @Test func qaTLSStageSurvivesCloseAndRejectsUntrustedText() {
        var capture = WebKitStartupDiagnosticCapture.Tokens()
        capture.append(Data((
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-tls-challenge\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-tls-anchors-ok\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=qa-tls-eval-m9807\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=close-callback\n").utf8))
        #expect(WebKitHostClient.childQATLSStage(capture.snapshot) == "qa-tls-eval-m9807")
        #expect(WebKitHostClient.childStartupStage(capture.snapshot) == "close-callback")
        #expect(WebKitHostClient.childQATLSStage(Data(
            "NEANTIK_WEBKIT_QA_TLS stage=qa-tls-host-private.example\n".utf8)) == nil)
        #expect(WebKitHostClient.childQATLSStage(Data(
            "NEANTIK_WEBKIT_QA_TLS stage=qa-tls-eval-m1234567\n".utf8)) == nil)
    }

    @Test func childStartupDiagnosticsParseFailureAfterFullBoundedStageTrace() {
        let stages = [
            "child-entry", "identity-verified", "runtime-attested", "pipes-ready",
            "bootstrap-received", "profile-acquired", "bootstrap-accepted",
        ]
        let trace = stages.map {
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=\($0)"
        }.joined(separator: "\n") +
            "\nNEANTIK_WEBKIT_STARTUP_FAILURE code=runtime-runtimeHashMismatch\n"
        let data = Data(trace.utf8)

        #expect(data.count <= 1024)
        #expect(WebKitHostClient.childStartupStage(data) == "bootstrap-accepted")
        #expect(WebKitHostClient.childStartupDiagnosticCode(data) == "runtime-runtimeHashMismatch")
    }

    @Test func childStartupClosedAndTimedOutErrorsRetainLastSafeStage() {
        let data = Data(("NEANTIK_WEBKIT_STARTUP_STAGE stage=child-entry\n" +
            "NEANTIK_WEBKIT_STARTUP_STAGE stage=runtime-attested\n").utf8)
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: ProxyRelayPrivatePipe.Failure.closed, data: data) ==
            .childStartupClosed(stage: "runtime-attested"))
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: ProxyRelayPrivatePipe.Failure.timeout, data: data) ==
            .childStartupTimedOut(stage: "runtime-attested"))
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: ProxyRelayPrivatePipe.Failure.closed, data: Data()) == nil)
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: ProxyRelayPrivatePipe.Failure.malformed, data: data) == nil)
    }

    @Test func childRefusalRetainsBoundedStageForPrivateQA() {
        let data = Data(("NEANTIK_WEBKIT_STARTUP_STAGE stage=identity-verified\n" +
            "NEANTIK_WEBKIT_STARTUP_FAILURE code=runtime-missingRuntimeImage\n").utf8)
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: ProxyRelayPrivatePipe.Failure.closed, data: data) ==
            .childRefusedStartup(code: "runtime-missingRuntimeImage", stage: "identity-verified"))
    }

    @Test func childPipeClosurePreservesTheParentsFirstFailure() {
        let data = Data(("NEANTIK_WEBKIT_STARTUP_STAGE stage=bootstrap-accepted\n" +
            "NEANTIK_WEBKIT_STARTUP_FAILURE code=pipe-closed\n").utf8)
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: WebKitHostClient.Failure.invalidChild, data: data) ==
            .childRefusedStartup(code: "pipe-closed-parent-invalidChild", stage: "bootstrap-accepted"))
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: ProxyRelayPrivatePipe.Failure.closed, data: data) ==
            .childRefusedStartup(code: "pipe-closed-parent-pipeClosed", stage: "bootstrap-accepted"))
        #expect(WebKitStartupDiagnosticCapture.Tokens.isSafeFailureCode("pipe-closed-parent-invalidChild"))
        #expect(!WebKitStartupDiagnosticCapture.Tokens.isSafeFailureCode("pipe-closed-parent-private-path"))
    }

    @Test func parentRegistrationFailureRemainsDiagnosableWithoutChildStage() {
        let data = Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=pipe-closed\n".utf8)
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: WebKitHostLeaseReservation.Failure.guardNotHeld,
            data: data,
            parentStartStep: "parent-registering") ==
            .childRefusedStartup(code: "pipe-closed-parent-leaseGuardNotHeld",
                                 stage: "parent-registering"))
        #expect(WebKitStartupDiagnosticCapture.Tokens.isSafeFailureCode(
            "pipe-closed-parent-leaseGuardNotHeld"))
        #expect(WebKitStartupDiagnosticCapture.Tokens.stages.contains("parent-registering"))
    }

    @Test func parentTimeoutsIdentifyTheExactIPCWaitWhenChildMarkersAreAbsent() {
        let timeout = ProxyRelayPrivatePipe.Failure.timeout
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: timeout, data: nil,
            parentWaitPhase: .bootstrapAcknowledgement) ==
            .parentStartupTimedOut(phase: .bootstrapAcknowledgement))
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: timeout, data: Data(),
            parentWaitPhase: .networkProcessOwner) ==
            .parentStartupTimedOut(phase: .networkProcessOwner))
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: timeout, data: Data(),
            parentWaitPhase: .routeReady) ==
            .parentStartupTimedOut(phase: .routeReady))
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: timeout, data: nil) == nil)
    }

    @Test func childStageRemainsMoreSpecificThanParentWaitPhase() {
        let trace = Data("NEANTIK_WEBKIT_STARTUP_STAGE stage=profile-acquired\n".utf8)
        #expect(WebKitHostClient.startupDiagnosticFailure(
            error: ProxyRelayPrivatePipe.Failure.timeout, data: trace,
            parentWaitPhase: .bootstrapAcknowledgement) ==
            .childStartupTimedOut(stage: "profile-acquired"))
    }

    @Test func startupDiagnosticDrainClosesParentWriterBeforeWaitingForEOF() {
        let pipe = Pipe()
        let expected = Data("NEANTIK_WEBKIT_STARTUP_STAGE stage=child-entry\n".utf8)
        try? pipe.fileHandleForWriting.write(contentsOf: expected)
        #expect(WebKitHostClient.drainStartupDiagnostic(from: pipe) == expected)
    }

    @Test func startupDiagnosticCanBeDrainedWithoutWaitingForChildEOF() {
        let pipe = Pipe()
        let expected = Data("NEANTIK_WEBKIT_STARTUP_STAGE stage=network-owner-resolved\n".utf8)
        try? pipe.fileHandleForWriting.write(contentsOf: expected)
        #expect(WebKitHostClient.drainAvailableStartupDiagnostic(
            from: pipe.fileHandleForReading.fileDescriptor) == expected)
        // The writer intentionally remains open: this must be an immediate,
        // bounded observation, not a blocking readToEnd waiting for EOF.
        #expect(pipe.fileHandleForWriting.fileDescriptor >= 0)
    }

    @Test func startupCaptureRejectsNoiseAndRetainsSplitLateMarkers() {
        var tokens = WebKitStartupDiagnosticCapture.Tokens()
        // The old prefix buffer discarded all markers after byte 1024.
        tokens.append(Data(repeating: 120, count: 4096))
        tokens.append(Data("NEANTIK_WEBKIT_STARTUP_STAGE stage=ready-sent\n".utf8))
        #expect(tokens.snapshot.isEmpty) // embedded in an oversized line
        tokens.append(Data("private-profile-cookie-secret\nNEANTIK_WEBKIT_STARTUP_STAGE stage=secret\n".utf8))
        tokens.append(Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=secret\n".utf8))
        #expect(tokens.snapshot.isEmpty)
        tokens.append(Data("NEANTIK_WEBKIT_STARTUP_STA".utf8))
        tokens.append(Data("GE stage=host-entry\n".utf8))
        tokens.append(Data("NEANTIK_WEBKIT_STARTUP_STAGE stage=profile-acquired\n".utf8))
        tokens.append(Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=runtime-runtimeHashMismatch\n".utf8))
        tokens.append(Data("NEANTIK_WEBKIT_STARTUP_FAILURE code=pipe-closed\n".utf8))
        #expect(WebKitHostClient.childStartupStage(tokens.snapshot) == "profile-acquired")
        #expect(WebKitHostClient.childStartupDiagnosticCode(tokens.snapshot) == "runtime-runtimeHashMismatch")
        #expect(!String(decoding: tokens.snapshot, as: UTF8.self).contains("secret"))
        #expect(tokens.snapshot.count < 256)
    }

    @Test func startupCaptureDrainsBeyondPipeCapacityWhileWriterRemainsOpen() async throws {
        let pipe = Pipe()
        let capture = try #require(WebKitStartupDiagnosticCapture(handle: pipe.fileHandleForReading))
        defer { try? pipe.fileHandleForWriting.close(); capture.close() }
        let fd = pipe.fileHandleForWriting.fileDescriptor
        #expect(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0)
        #expect(fcntl(fd, F_SETNOSIGPIPE, 1) == 0)
        let marker = "NEANTIK_WEBKIT_STARTUP_STAGE stage=bootstrap-received\n"
        let bytes = Data((String(repeating: "noise\n", count: 32_768) + marker).utf8)
        let written = await Task.detached {
            var offset = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while offset < bytes.count, ContinuousClock.now < deadline {
                let count = bytes.withUnsafeBytes {
                    write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0, errno == EAGAIN || errno == EINTR {
                    try? await Task.sleep(for: .milliseconds(1))
                } else { break }
            }
            return offset
        }.value
        #expect(written == bytes.count)
        let captured = capture.snapshot()
        #expect(WebKitHostClient.childStartupStage(captured) == "bootstrap-received")
        #expect(captured == Data(marker.utf8))
        capture.close()
        #expect(capture.snapshot() == captured) // close is idempotent; no FD reuse read
        capture.close()
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

    @Test func readOnlyHostReaderRejectsDuplicateIdentityAndPendingRestore() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = try ProfileStore(paths: paths).upsert(BrowserProfile(
            name: "Read-only QA", startURL: "about:blank", engine: .webkit,
            webKitRuntimeGeneration: .isolatedV1))
        let loaded = try WebKitHostProfileReader.profile(id: profile.id, paths: paths)
        #expect(loaded.id == profile.id)
        #expect(loaded.revision == profile.revision)
        #expect(loaded.webKitRuntimeGeneration == .isolatedV1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let duplicate = try ProfileStore.encodeProfiles([profile, profile], encoder: encoder)
        try paths.writePrivateFile(duplicate, to: paths.profilesFile)
        #expect(throws: WebKitHostProfileReader.Failure.duplicateIdentity) {
            _ = try WebKitHostProfileReader.profile(id: profile.id, paths: paths)
        }

        try paths.writePrivateFile(try ProfileStore.encodeProfiles([profile], encoder: encoder),
                                   to: paths.profilesFile)
        let pending = root.appendingPathComponent(".browser-data-restore-active", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        #expect(throws: WebKitHostProfileReader.Failure.unavailable) {
            try WebKitHostProfileReader.requireNoPending(rootURL: root)
        }
        #expect(throws: BrowserDataRestoreError.pending) {
            _ = try WebKitHostProfileReader.profile(id: profile.id, paths: paths)
        }
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
