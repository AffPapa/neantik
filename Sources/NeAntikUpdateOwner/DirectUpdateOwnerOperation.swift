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
        let trust = try DirectUpdateOwnerAuthentication.authenticate()
        let request = try DirectUpdateOwnerInit.parse(DirectUpdateOwnerPipe.readFrame(STDIN_FILENO, timeoutMS: 10_000))
        let manifest = try DirectUpdateOwnerPipe.readFrame(STDIN_FILENO, timeoutMS: 10_000)
        try request.validateManifest(manifest); try trust.validate(requireParent: true)
        let metadata = trust.policy.metadata
        let coordinator = DirectUpdateAdmissionCoordinator(configuration: metadata.configuration,
            installedVersion: metadata.version, installedBuild: metadata.build,
            assessmentHelper: { try trust.workspace.validate(); return trust.workspace.assessment })
        let control = OwnerDecisionControl(request: request)
        let inspection = Task {
            let result = try await coordinator.inspectLocalArchive(request.archive, signedManifest: manifest,
                archiveParent: trust.workspace.archives, extractionParent: trust.workspace.apps)
            guard case .observed = result.system.reply else { throw DirectUpdateOwnerProtocolError.reply }
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
            try trust.validate(requireParent: true)
            let offer = try DirectUpdateOwnerOffer(request: request, observation: result)
            try control.publishOffer()
            try writeFrame(offer.bytes)
            let command = try await decisionReader.value
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
            try writeFrame(DirectUpdateOwnerConsent.accepted(request: request, offer: offer))
            try DirectUpdateOwnerPipe.expectEOF(STDIN_FILENO)
            close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO)
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
            let installed = try await DirectUpdateInstallDriver.run(lease: lease, slot: slot, expectedCode: code,
                cdHash: result.system.managerCDHash, build: UInt64(result.build), runtimeSHA256: result.runtime.runtimeSHA256,
                validateCandidate: validateCandidate)
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
