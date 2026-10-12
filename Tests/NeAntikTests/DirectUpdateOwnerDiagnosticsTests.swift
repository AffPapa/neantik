import DirectUpdateCore
import Foundation
import Testing

@Suite("Installer diagnostic redaction")
struct DirectUpdateOwnerDiagnosticsTests {
    @Test func knownFailuresHaveUsefulFixedNames() {
        #expect(DirectUpdateOwnerDiagnostics.failureCode(DirectUpdateInstallSessionError.identity) == "session.identity")
        #expect(DirectUpdateOwnerDiagnostics.failureCode(DirectUpdateCodeSignatureError.changed) == "signature.changed")
        #expect(DirectUpdateOwnerDiagnostics.failureCode(DirectAssessmentParentError.wait) == "assessment.wait")
        #expect(DirectUpdateOwnerDiagnostics.failureCode(CancellationError()) == "cancelled")
    }
    @Test func arbitraryErrorNeverDisclosesItsDescription() {
        let error = NSError(domain: "private/profile/proxy-secret", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "token=fixture-sensitive-value"])
        #expect(DirectUpdateOwnerDiagnostics.failureCode(error) == "unclassified")
    }
}
