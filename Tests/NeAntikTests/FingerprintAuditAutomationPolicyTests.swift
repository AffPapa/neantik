import Testing
@testable import NeAntik

struct FingerprintAuditAutomationPolicyTests {
    @Test
    func manualAuditPresentsAnErrorAlert() {
        #expect(
            FingerprintAuditAutomationPolicy.errorPresentation(
                isReleaseAudit: false,
                errorMessage: "Ошибка"
            ) == .manualAlert
        )
    }

    @Test
    func releaseAuditTerminatesWithoutPresentingAnAlert() {
        #expect(
            FingerprintAuditAutomationPolicy.errorPresentation(
                isReleaseAudit: true,
                errorMessage: "Ошибка"
            ) == .automatedTermination
        )
    }

    @Test
    func absentErrorDoesNotPresentOrTerminate() {
        #expect(
            FingerprintAuditAutomationPolicy.errorPresentation(
                isReleaseAudit: true,
                errorMessage: nil
            ) == .hidden
        )
    }

    @Test
    func releaseLogIsSingleLineAndBounded() {
        let line = FingerprintAuditAutomationPolicy.sanitizedLogLine(
            prefix: "Ошибка: ",
            message: String(repeating: "x", count: 2_000) + "\nsecret"
        )

        #expect(!line.dropLast().contains("\n"))
        #expect(line.hasSuffix("\n"))
        #expect(line.count <= 1_033)
    }
}
