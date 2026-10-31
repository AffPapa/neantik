import DirectInstallFilesystem
import Foundation

package struct DirectUpdateInstallOutcome: Equatable, Sendable {
    package let decision: InstallFilesystemResult
    package let handedOff: Bool
    package let processID: Int32?
    package let refusal: String?
    package let failurePhase: String?
}

/// The independent owner retains admission and the prepared slot. This driver
/// joins filesystem custody and authenticated readiness; it cannot admit an
/// archive, choose channel policy, or infer success from a scalar receipt.
package enum DirectUpdateInstallDriver {
    package static func run(lease: InstallFilesystemLease, slot: PreparedInstallSlot,
                            expectedCode: ProxyRelayExpectedCode, cdHash: Data, build: UInt64,
                            runtimeSHA256: String,
                            validateCandidate: @escaping (URL) throws -> Void,
                            validateReady: ((DirectUpdateCandidateReadiness) throws -> Void)? = nil,
                            auditIsolation: DirectUpdateAuditIsolation? = nil, auditRecordDirectory: URL? = nil,
                            fault: ((InstallFilesystemPoint) throws -> Void)? = nil) async throws -> DirectUpdateInstallOutcome {
        let app = try lease.validatedApplicationURL()
        let authority = try DirectUpdateStoppedAuthority(installation: app)
        try authority.validateStopped()
        try slot.withValidatedCandidate(validateCandidate)
        var receipt: InstallFilesystemReceipt?
        var completed: InstallFilesystemResult?
        var fencesReleased = false
        var phase = "begin"
        var custodyChecks = 0
        do {
            let pending = try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot,
                validateStoppedAuthority: { try authority.validateStopped() }, fault: fault)
            receipt = pending
            let request = try DirectUpdateBootstrapRequest(receipt: pending, cdHash: cdHash, build: build,
                runtimeSHA256: runtimeSHA256)
            let auditRecordDigest: Data?
            if let auditIsolation {
                guard let auditRecordDirectory else { throw DirectUpdateInstallSessionError.custody }
                auditRecordDigest = try DirectUpdateAuditRecord.publish(auditIsolation, request: request, directory: auditRecordDirectory)
            } else {
                guard auditRecordDirectory == nil else { throw DirectUpdateInstallSessionError.custody }
                auditRecordDigest = nil
            }
            phase = "bootstrap"
            let pid = try await DirectUpdateInstallSession.run(candidate: app.appendingPathComponent("Contents/MacOS/NeAntik"),
                request: request, expectedCode: expectedCode,
                validateCustody: {
                    try auditIsolation?.validate()
                    custodyChecks += 1
                    phase = "custody-lease"
                    guard try lease.validatedApplicationURL() == app else { throw DirectUpdateInstallSessionError.custody }
                    phase = "custody-receipt"
                    guard try InstallFilesystemTransaction.pendingReceipt(lease: lease,
                        observeValidation: { phase = "receipt-\(custodyChecks)-" + $0 }) == pending else {
                        throw DirectUpdateInstallSessionError.custody
                    }
                    phase = "custody-signature"
                    try validateCandidate(app)
                    phase = "custody-complete"
                }, onReady: { readiness in
                    phase = "readiness"
                    try authority.validateLaunch(readiness, receipt: pending)
                    try validateReady?(readiness)
                    completed = try InstallFilesystemTransaction.acknowledge(lease: lease, expected: pending,
                        validateLaunchAuthority: { try authority.validateLaunch(readiness, receipt: pending) }, fault: fault)
                    try authority.releaseAfterCompletion(); fencesReleased = true
                }, auditRecordDigest: auditRecordDigest)
            guard let completed, completed.committed, fencesReleased else { throw DirectUpdateInstallSessionError.handoff }
            return .init(decision: completed, handedOff: true, processID: pid, refusal: nil, failurePhase: nil)
        } catch {
            let originalError = error
            let refusal: String
            if let error = error as? DirectUpdateInstallSessionError { refusal = "session." + String(describing: error) }
            else if let error = error as? InstallFilesystemError { refusal = "filesystem." + String(describing: error) }
            else if let error = error as? BrowserDataBackupStorageError { refusal = "storage." + String(describing: error) }
            else { refusal = "unclassified" }
            // Session failure has killed/reaped its exact owned child before it
            // throws. A successful ACK is independent of continue pipe success.
            if let completed, fencesReleased {
                return .init(decision: completed, handedOff: false, processID: nil, refusal: refusal, failurePhase: phase)
            }
            // Caller cancellation must not cancel the recovery that restores
            // the old slot or completes a visibly published new-slot decision.
            let recovered = try await Task.detached(priority: .utility) { () throws -> InstallFilesystemResult? in
                try authority.validateStopped()
                if let result = try InstallFilesystemTransaction.recover(lease: lease,
                    validateStoppedAuthority: { try authority.validateStopped() }) {
                    try authority.releaseAfterCompletion()
                    return result
                }
                if let receipt, let result = try InstallFilesystemTransaction.finalizedResult(lease: lease, expected: receipt) {
                    try authority.releaseAfterCompletion()
                    return result
                }
                // No active/finalized exact journal means no completed install.
                // Transfer/preparing evidence remains retained for diagnosis.
                try authority.releaseAfterCompletion()
                return nil as InstallFilesystemResult?
            }.value
            if let recovered { return .init(decision: recovered, handedOff: false, processID: nil, refusal: refusal, failurePhase: phase) }
            throw originalError
        }
    }
}
