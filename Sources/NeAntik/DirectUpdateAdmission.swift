import CryptoKit
import Foundation

enum DirectUpdateAdmissionPhase: String, Sendable, CaseIterable {
    case manifest, archive, extraction, signature, runtime, systemAssessment, finalBinding
}
enum DirectUpdateAdmissionState: Equatable, Sendable {
    case idle, checking(DirectUpdateAdmissionPhase), observed, refused(Int)
    case failed(DirectUpdateAdmissionPhase), cancelled(DirectUpdateAdmissionPhase)
}
enum DirectUpdateAdmissionError: Error, Equatable { case alreadyAttempted, binding }

/// Scalar outcome of the whole local candidate check. It is deliberately not
/// Codable and never authorizes swapping/launching an app or migrating data.
/// In particular a system refusal cannot be promoted to a ready candidate.
struct DirectUpdateAdmissionObservation: Sendable {
    let manifestSHA256: String
    let version: String, build: Int, archiveSHA256: String
    let signatures: [DirectUpdateCodeSignatureObservation]
    let runtime: DirectUpdateRuntimeProvenanceObservation
    let system: DirectSystemAssessmentObservation
    var installAuthorized: Bool { false }
    fileprivate init(manifestSHA256: String, payload: UpdateManifestPayload,
                     signature: DirectUpdateStageSignature, runtime: DirectUpdateRuntimeProvenanceObservation,
                     system: DirectSystemAssessmentObservation) {
        self.manifestSHA256 = manifestSHA256; version = payload.version
        build = payload.build; archiveSHA256 = payload.sha256
        signatures = signature.observations; self.runtime = runtime; self.system = system
    }
}

/// One attempt owns one archive and one extracted stage. Actor reentrancy
/// cannot start a second candidate or overwrite a failure. All disk, crypto
/// and Security work is awaited utility work, including final custody checks.
/// Unchanged/unknown files remain retained on refusal; no process is stopped,
/// app installed, profile read, key adopted or network download performed.
actor DirectUpdateAdmissionCoordinator {
    private let configuration: UpdateChannelConfiguration
    private let installedVersion: String, installedBuild: Int
    private let hostOS: OperatingSystemVersion
    private let clock: @Sendable () -> Date
    // This factory is supplied by installed trusted policy, never by the
    // archive/manifest or an external management client.
    private let assessmentHelper: @Sendable () throws -> DirectAssessmentHelper
    private var state: DirectUpdateAdmissionState = .idle
    private var archive: PreparedUpdateArchive?
    private var stage: ExtractedUpdateApp?
    private var signature: DirectUpdateStageSignature?
    private var observation: DirectUpdateAdmissionObservation?

    init(configuration: UpdateChannelConfiguration, installedVersion: String, installedBuild: Int,
         hostOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
         clock: @escaping @Sendable () -> Date = { Date() },
         assessmentHelper: @escaping @Sendable () throws -> DirectAssessmentHelper) {
        self.configuration = configuration; self.installedVersion = installedVersion
        self.installedBuild = installedBuild; self.hostOS = hostOS
        self.clock = clock; self.assessmentHelper = assessmentHelper
    }
    func snapshot() -> DirectUpdateAdmissionState { state }

    func inspectLocalArchive(_ source: URL, signedManifest: Data, archiveParent: URL, extractionParent: URL,
                             beforePhase: (@Sendable (DirectUpdateAdmissionPhase) throws -> Void)? = nil,
                             archiveFault: (@Sendable (DirectUpdateStagePoint) throws -> Void)? = nil,
                             extractionFault: (@Sendable (DirectUpdateZIPExtractionPoint) throws -> Void)? = nil) async throws -> DirectUpdateAdmissionObservation {
        guard state == .idle else { throw DirectUpdateAdmissionError.alreadyAttempted }
        state = .checking(.manifest)
        var phase = DirectUpdateAdmissionPhase.manifest
        do {
            try await boundary(phase, beforePhase)
            let configuration = self.configuration, version = installedVersion, build = installedBuild
            let host = hostOS, clock = self.clock
            let verified = try await utility {
                try DirectUpdateArchiveIntegrityService.admittedManifest(signedManifest, configuration: configuration,
                    installedVersion: version, installedBuild: build, hostOS: host, now: clock())
            }
            phase = .archive; try await boundary(phase, beforePhase)
            let ownedArchive = try await DirectUpdateStageStorage.prepareLocalArchive(archiveURL: source,
                signedManifest: signedManifest, configuration: configuration, installedVersion: version,
                installedBuild: build, destinationParent: archiveParent, hostOS: host, clock: clock, fault: archiveFault)
            archive = ownedArchive
            phase = .extraction; try await boundary(phase, beforePhase)
            let ownedStage = try await DirectUpdateZIPExtraction.extract(ownedArchive, destinationParent: extractionParent, fault: extractionFault)
            stage = ownedStage
            phase = .signature; try await boundary(phase, beforePhase)
            let boundSignature = try await DirectUpdateCodeSignature.inspectBoundStage(ownedStage)
            signature = boundSignature
            phase = .runtime; try await boundary(phase, beforePhase)
            let runtime = try await DirectUpdateRuntimeProvenance.inspectStageAsynchronously(ownedStage, signature: boundSignature)
            phase = .systemAssessment; try await boundary(phase, beforePhase)
            let factory = assessmentHelper
            let helper = try await utility { try factory() }
            let system = try await DirectAssessmentParent.observe(stage: ownedStage, signature: boundSignature, helper: helper)
            phase = .finalBinding; try await boundary(phase, beforePhase)
            let result = try await utility {
                let fresh = try DirectUpdateArchiveIntegrityService.admittedManifest(signedManifest, configuration: configuration,
                    installedVersion: version, installedBuild: build, hostOS: host, now: clock())
                guard fresh == verified, system.managerCDHash == boundSignature.manager.cdHash else { throw DirectUpdateAdmissionError.binding }
                try boundSignature.requireBinding(to: ownedStage)
                try ownedArchive.withValidatedArchive { _, integrity in
                    try Self.requireBinding(integrity, payload: fresh.payload)
                }
                try ownedStage.withValidatedApp { _ in try Self.requireBinding(ownedStage.archiveIntegrity, payload: fresh.payload) }
                // Custody checks can take time on a large app. Recheck expiry
                // after them as well; their start time cannot refresh a ticket.
                guard try DirectUpdateArchiveIntegrityService.admittedManifest(signedManifest, configuration: configuration,
                    installedVersion: version, installedBuild: build, hostOS: host, now: clock()) == fresh else {
                    throw DirectUpdateAdmissionError.binding
                }
                try boundSignature.requireBinding(to: ownedStage)
                return DirectUpdateAdmissionObservation(manifestSHA256: BackupFS.hex(SHA256.hash(data: signedManifest)),
                    payload: fresh.payload, signature: boundSignature, runtime: runtime, system: system)
            }
            try Task.checkCancellation()
            observation = result
            switch system.reply {
            case .observed: state = .observed
            case .refused(let status, _, _, _, _, _): state = .refused(status)
            }
            return result
        } catch {
            if error is CancellationError || (error as? DirectAssessmentParentError) == .cancelled { state = .cancelled(phase) }
            else { state = .failed(phase) }
            throw error
        }
    }

    private func boundary(_ phase: DirectUpdateAdmissionPhase,
                          _ fault: (@Sendable (DirectUpdateAdmissionPhase) throws -> Void)?) async throws {
        state = .checking(phase)
        try await utility { try fault?(phase) }
    }
    private func utility<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try work() }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation(); return value
        } onCancel: { task.cancel() }
    }
    private nonisolated static func requireBinding(_ integrity: UpdateArchiveIntegrityReceipt, payload: UpdateManifestPayload) throws {
        guard integrity.schemaVersion == 1, integrity.version == payload.version, integrity.build == payload.build,
              integrity.chromiumVersion == payload.chromiumVersion, integrity.sha256 == payload.sha256,
              integrity.archiveBytes > 0, integrity.manifestSignatureVerified, integrity.archiveBytesMatchManifest,
              !integrity.installed else { throw DirectUpdateAdmissionError.binding }
    }
}
