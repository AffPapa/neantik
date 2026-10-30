import Darwin
import DirectInstallFilesystem
import DirectUpdateBootstrapParent
import DirectUpdateCore
import Foundation

/// One operation in an independent process. No request-supplied policy,
/// installation target, helper, credentials or profile path is accepted.
enum DirectUpdateOwnerOperation {
    static func run() async throws {
        var cancellationReply = DirectUpdateOwnerCancellationReply()
        DirectUpdateOwnerDiagnostics.phase(.authenticate)
        let trust = try DirectUpdateOwnerAuthentication.authenticate()
        DirectUpdateOwnerDiagnostics.phase(.request)
        let request = try DirectUpdateOwnerInit.parse(DirectUpdateOwnerPipe.readFrame(STDIN_FILENO, timeoutMS: 10_000))
        let manifest = try DirectUpdateOwnerPipe.readFrame(STDIN_FILENO, timeoutMS: 10_000)
        try request.validateManifest(manifest); try trust.validate(requireParent: true)
        DirectUpdateOwnerDiagnostics.phase(.audit)
        let auditIsolation = try request.auditFrame.map { try DirectUpdateAuditIsolation.adoptAuthenticatedFrame($0) }
        let metadata = trust.policy.metadata
        let coordinator = DirectUpdateAdmissionCoordinator(configuration: metadata.configuration,
            installedVersion: metadata.version, installedBuild: metadata.build,
            assessmentHelper: { try trust.workspace.validate(); return trust.workspace.assessment })
        let control = OwnerDecisionControl(request: request)
        let inspection = Task {
            DirectUpdateOwnerDiagnostics.phase(.inspection)
            let result = try await coordinator.inspectLocalArchive(request.archive, signedManifest: manifest,
                archiveParent: trust.workspace.archives, extractionParent: trust.workspace.apps,
                beforePhase: { DirectUpdateOwnerDiagnostics.admissionPhase($0) })
            guard case .observed = result.system.reply else { throw DirectUpdateOwnerProtocolError.reply }
            DirectUpdateOwnerDiagnostics.phase(.retainedCandidate)
            let candidate = try await coordinator.validateRetainedCandidate(ownerCDHash: metadata.owner.cdHash)
            try trust.validate(requireParent: true)
            return (result, candidate)
        }
        control.onEarlyStop { inspection.cancel() }
        let decisionReader = Task.detached(priority: .utility) {
            do {
                let frame = try DirectUpdateOwnerPipe.readFrame(STDIN_FILENO, timeoutMS: 300_000, cancellation: control.pipeCancellation)
                try control.receive(frame); return frame
            } catch { control.stopInspection(); throw error }
        }
        let result: DirectUpdateAdmissionObservation, candidatePolicy: DirectUpdateInstalledMetadata
        do {
            (result, candidatePolicy) = try await inspection.value
        } catch {
            control.cancelIO()
            let frame = try? await decisionReader.value
            if frame == DirectUpdateOwnerConsent.earlyCancel(request: request) {
                // The cancelled admission task is awaited above, including its
                // actual assessment helper cleanup, before acknowledging.
                try cancellationReply.acknowledge(request)
                return
            }
            throw error
        }
        do {
            DirectUpdateOwnerDiagnostics.phase(.trust)
            try trust.validate(requireParent: true)
            try auditIsolation?.validate()
            DirectUpdateOwnerDiagnostics.phase(.offer)
            let offer = try DirectUpdateOwnerOffer(request: request, observation: result)
            try control.publishOffer()
            try writeFrame(offer.bytes)
            let command = try await decisionReader.value
            DirectUpdateOwnerDiagnostics.phase(.consent)
            if command == DirectUpdateOwnerConsent.earlyCancel(request: request) {
                try cancellationReply.acknowledge(request); return
            }
            switch try DirectUpdateOwnerConsent.parseCommand(command, request: request, offer: offer) {
            case .cancel:
                try cancellationReply.acknowledge(request); return
            case .commit: break
            }
            // Revalidate retained admission after the user's potentially long
            // wait. An expired manifest, changed payload or live code refuses
            // before Accepted and before asking the manager to quit.
            guard try await coordinator.validateRetainedCandidate(ownerCDHash: metadata.owner.cdHash) == candidatePolicy else {
                throw DirectUpdateAdmissionError.binding
            }
            try trust.validate(requireParent: true)
            try auditIsolation?.validate()
            try writeFrame(DirectUpdateOwnerConsent.accepted(request: request, offer: offer))
            try DirectUpdateOwnerPipe.expectEOF(STDIN_FILENO)
            // End manager transport without allowing bootstrap pipes to take
            // fd 0..2. Closed standard IO previously refused before spawn.
            guard neantik_update_owner_detach_standard_io() == 1 else {
                throw DirectUpdateInstallSessionError.io
            }
            DirectUpdateOwnerDiagnostics.phase(.managerExit)
            try await trust.waitForManagerExit()
            try DirectUpdateStoppedAuthority.requireQuietInventory()
            let lease = try InstallFilesystemLease(parentURL: trust.installation.deletingLastPathComponent())
            guard try lease.validatedApplicationURL().path == trust.installation.path else { throw DirectUpdateInstallSessionError.custody }
            let slot = try await coordinator.prepareInstallSlot(lease: lease)
            let validateCandidate: (URL) throws -> Void = { app in
                try DirectUpdateArchiveIntegrityService.withAdmittedManifest(manifest, configuration: metadata.configuration,
                    installedVersion: metadata.version, installedBuild: metadata.build,
                    hostOS: ProcessInfo.processInfo.operatingSystemVersion) {
                    let code = try DirectUpdateCodeSignature.inspect(app, role: .manager)
                    try code.requireReleaseCertificate()
                    guard code.cdHash == result.system.managerCDHash, code.version == result.version,
                          code.build == String(result.build), try code.installedUpdateMetadata() == candidatePolicy else {
                        throw DirectUpdateInstallSessionError.identity
                    }
                    try trust.workspace.validate()
                }
            }
            let code = try slot.withValidatedCandidate { app in
                try validateCandidate(app)
                return try ProxyRelayExpectedCode.qualifiedPin(at: app, expectedIdentifier: DirectUpdateCodeRole.manager.identifier,
                    expectedTeamIdentifier: DirectUpdateCodeSignature.team, expectedCDHash: result.system.managerCDHash)
            }
            DirectUpdateOwnerDiagnostics.phase(.install)
            let installed = try await DirectUpdateInstallDriver.run(lease: lease, slot: slot, expectedCode: code,
                cdHash: result.system.managerCDHash, build: UInt64(result.build), runtimeSHA256: result.runtime.runtimeSHA256,
                validateCandidate: validateCandidate, auditIsolation: auditIsolation,
                auditRecordDirectory: auditIsolation == nil ? nil : trust.workspace.apps)
            guard installed.decision.committed, installed.handedOff else { throw DirectUpdateInstallSessionError.handoff }
        } catch {
            control.cancelIO(); inspection.cancel()
            let frame = try? await decisionReader.value; _ = await inspection.result
            if frame == DirectUpdateOwnerConsent.earlyCancel(request: request) {
                try cancellationReply.acknowledge(request); return
            }
            throw error
        }
    }
    private static func writeFrame(_ bytes: Data) throws {
        try DirectUpdateOwnerPipe.writeFrame(bytes, to: STDOUT_FILENO)
    }
}

private final class OwnerDecisionControl: @unchecked Sendable {
    let pipeCancellation = DirectUpdateOwnerPipeCancellation()
    private let lock = NSLock(), request: DirectUpdateOwnerInit
    private var offered = false, stopped = false
    private var earlyStop: (() -> Void)?
    init(request: DirectUpdateOwnerInit) { self.request = request }
    func onEarlyStop(_ callback: @escaping () -> Void) {
        lock.lock(); earlyStop = callback; let stop = stopped; lock.unlock()
        if stop { callback() }
    }
    func stopInspection() {
        lock.lock(); stopped = true; let action = earlyStop; earlyStop = nil; lock.unlock(); action?()
    }
    func receive(_ frame: Data) throws {
        lock.lock(); let isOffered = offered; lock.unlock()
        if frame == DirectUpdateOwnerConsent.earlyCancel(request: request) { stopInspection(); return }
        guard isOffered else { stopInspection(); throw DirectUpdateOwnerProtocolError.binding }
    }
    func publishOffer() throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }; offered = true; earlyStop = nil
    }
    func cancelIO() { pipeCancellation.cancel() }
}
