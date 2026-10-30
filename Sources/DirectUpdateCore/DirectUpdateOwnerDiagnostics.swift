import Foundation
import OSLog

/// Bounded local diagnostics for the genuine installer. Only fixed phase/error
/// names and native integer statuses are recorded; never describe an arbitrary
/// Error, URL, manifest, profile or credential. These records grant no authority.
package enum DirectUpdateOwnerDiagnostics {
    private static let logger = Logger(subsystem: "app.neantik.desktop", category: "direct-update")
    package static func phase(_ name: Phase) {
        logger.notice("Installer phase: \(name.rawValue, privacy: .public)")
    }
    package static func admissionPhase(_ phase: DirectUpdateAdmissionPhase) {
        logger.notice("Installer admission: \(phase.rawValue, privacy: .public)")
    }
    package static func refused(_ error: Error) {
        logger.error("Installer refusal: \(failureCode(error), privacy: .public)")
    }
    package static func transport(_ status: Int32) {
        logger.error("Installer transport refusal: \(status, privacy: .public)")
    }
    package enum Phase: String { case authenticate, request, audit, inspection, retainedCandidate, trust, offer, consent, managerExit, install }
    package static func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let value = error as? DirectUpdateInstallSessionError { return "session." + String(describing: value) }
        if let value = error as? DirectUpdateCodeSignatureError { return "signature." + String(describing: value) }
        if let value = error as? DirectUpdateAdmissionError { return "admission." + String(describing: value) }
        if let value = error as? DirectAssessmentParentError { return "assessment." + String(describing: value) }
        if let value = error as? DirectUpdateOwnerProtocolError { return "protocol." + String(describing: value) }
        return "unclassified"
    }
}
