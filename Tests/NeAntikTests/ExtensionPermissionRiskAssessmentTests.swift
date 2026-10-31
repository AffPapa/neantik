import Testing
@testable import NeAntik

struct ExtensionPermissionRiskAssessmentTests {
    @Test
    func broadCapabilitiesAreExplainedWithoutInferringMaliciousnessOrGrants() {
        let warnings = ExtensionPermissionRiskAssessment.warnings(for: ["debugger", "proxy", "cookies", "<all_urls>", "<all_urls>"])
        #expect(warnings == [.allSites, .debugger, .proxy, .cookies])
        #expect(!ExtensionPermissionRiskAssessment.warnings(for: ["https://example.invalid/*", "storage"]).contains(.allSites))
        #expect(ExtensionPermissionRiskAssessment.warnings(for: ["http://*/*"]) == [.allSites])
    }

    @Test
    func optionalRightsStaySeparateAndManifestTextIsNotEchoedInWarnings() {
        let required = ExtensionPermissionRiskAssessment.warnings(for: ["storage"])
        let optional = ExtensionPermissionRiskAssessment.warnings(for: ["nativeMessaging", "clipboardRead", "https://private-marker.invalid/*"])
        #expect(required.isEmpty)
        #expect(optional == [.nativeMessaging, .clipboard])
        #expect(!optional.map(\.explanation).joined().contains("private-marker"))
    }
}
