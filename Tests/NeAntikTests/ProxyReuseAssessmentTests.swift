import Foundation
import Testing
@testable import NeAntik

struct ProxyReuseAssessmentTests {
    @Test
    func DNSHostComparisonIsCaseInsensitive() {
        let selectedID = UUID()
        let assessment = ProxyReuseAssessment.assess(
            selectedProfileID: selectedID,
            among: [
                Self.input(selectedID, .https, "Proxy.Example", 8443),
                Self.input(UUID(), .https, "proxy.example", 8443),
            ]
        )

        #expect(assessment.status == .shared)
        #expect(assessment.otherProfileCount == 1)
        #expect(
            assessment.warningText ==
                "Этот прокси назначен ещё 1 профилю. " +
                "Проверьте, должно ли подключение быть общим."
        )
    }

    @Test
    func bracketedAndUnbracketedIPv6HostsMatch() {
        let selectedID = UUID()
        let assessment = ProxyReuseAssessment.assess(
            selectedProfileID: selectedID,
            among: [
                Self.input(selectedID, .socks5, "[2001:DB8::1]", 1080),
                Self.input(UUID(), .socks5, "2001:db8::1", 1080),
            ]
        )

        #expect(assessment.status == .shared)
        #expect(assessment.otherProfileCount == 1)
    }

    @Test
    func differentSchemesAreDistinctRoutes() {
        let selectedID = UUID()
        let assessment = ProxyReuseAssessment.assess(
            selectedProfileID: selectedID,
            among: [
                Self.input(selectedID, .http, "proxy.example", 8080),
                Self.input(UUID(), .https, "proxy.example", 8080),
            ]
        )

        #expect(assessment.status == .dedicated)
        #expect(!assessment.shouldWarn)
    }

    @Test
    func differentPortsAreDistinctRoutes() {
        let selectedID = UUID()
        let assessment = ProxyReuseAssessment.assess(
            selectedProfileID: selectedID,
            among: [
                Self.input(selectedID, .https, "proxy.example", 8443),
                Self.input(UUID(), .https, "proxy.example", 9443),
            ]
        )

        #expect(assessment.status == .dedicated)
        #expect(!assessment.shouldWarn)
    }

    @Test
    func directProfilesNeverProduceAReuseWarning() {
        let selectedID = UUID()
        let assessment = ProxyReuseAssessment.assess(
            selectedProfileID: selectedID,
            among: [
                .direct(profileID: selectedID),
                .direct(profileID: UUID()),
            ]
        )

        #expect(assessment.status == .direct)
        #expect(assessment.otherProfileCount == 0)
        #expect(!assessment.shouldWarn)
    }

    @Test
    func duplicateRowsForTheSelectedProfileAreNotCounted() {
        let selectedID = UUID()
        let selected = Self.input(selectedID, .https, "proxy.example", 8443)
        let assessment = ProxyReuseAssessment.assess(
            selectedProfileID: selectedID,
            among: [selected, selected]
        )

        #expect(assessment.status == .dedicated)
        #expect(assessment.otherProfileCount == 0)
    }

    @Test
    func configurationAdapterDoesNotIncludeUsernameInComparison() {
        let first = ProxyReuseInput(
            profileID: UUID(),
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8443,
                username: "first-private-login"
            )
        )
        let second = ProxyReuseInput(
            profileID: first.profileID,
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8443,
                username: "different-private-login"
            )
        )

        #expect(first == second)
    }

    @Test
    func profileAdapterExcludesCurrentProfileAndCredentials() {
        let selected = BrowserProfile(
            name: "Selected",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8443,
                username: "private-login"
            )
        )
        let inputs = ProxyReuseInput.profiles(
            [selected, BrowserProfile(name: "Other", proxy: selected.proxy)],
            excluding: selected.id
        )

        #expect(inputs.count == 1)
        #expect(inputs[0].profileID != selected.id)
    }

    private static func input(
        _ profileID: UUID,
        _ kind: ProxyKind,
        _ host: String,
        _ port: Int
    ) -> ProxyReuseInput {
        ProxyReuseInput(
            profileID: profileID,
            kind: kind,
            host: host,
            port: port
        )
    }
}
