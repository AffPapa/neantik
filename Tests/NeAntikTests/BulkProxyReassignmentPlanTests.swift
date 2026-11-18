import Foundation
import Testing
@testable import NeAntik

struct BulkProxyReassignmentPlanTests {
    @Test
    func emptySelectionIsAnExplicitlyIncompletePlan() {
        let plan = BulkProxyReassignmentPlan.resolve(
            selectedProfiles: [],
            targets: []
        )

        #expect(plan.rows.isEmpty)
        #expect(!plan.isComplete)
    }

    @Test
    func duplicateNamesRemainDistinctByProfileIDAndMappingOrderIsStable() {
        let first = profile("Same name", revision: 3)
        let second = profile("Same name", revision: 7)
        let firstProxy = proxy(host: "one.example", username: "login-one")
        let secondProxy = proxy(host: "two.example", username: "login-two")

        let plan = BulkProxyReassignmentPlan.resolve(
            selectedProfiles: [first, second],
            targets: [
                .init(profileID: second.id, proxy: secondProxy),
                .init(profileID: first.id, proxy: firstProxy),
            ]
        )

        #expect(plan.isComplete)
        #expect(plan.rows.map(\.profileID) == [first.id, second.id])
        #expect(plan.rows.map(\.expectedRevision) == [3, 7])
        #expect(plan.rows.map(\.targetProxy?.endpoint) == [
            "one.example:8080", "two.example:8080",
        ])
    }

    @Test
    func incompleteAndAmbiguousAssignmentsAreExplicit() {
        let missing = profile("Missing")
        let duplicate = profile("Duplicate")
        let outsider = UUID()

        let plan = BulkProxyReassignmentPlan.resolve(
            selectedProfiles: [missing, duplicate],
            targets: [
                .init(profileID: duplicate.id, proxy: proxy(host: "a.example")),
                .init(profileID: duplicate.id, proxy: proxy(host: "b.example")),
                .init(profileID: outsider, proxy: proxy(host: "outside.example")),
            ]
        )

        #expect(!plan.isComplete)
        #expect(plan.rows[0].issues == [.missingTarget])
        #expect(plan.rows[1].issues == [.duplicateTarget])
        #expect(plan.rows[1].targetProxy == nil)
        #expect(plan.unselectedTargetProfileIDs == [outsider])
    }

    @Test
    func duplicateSelectionAndInvalidProxyCannotProduceCompletePlan() {
        let selected = profile("Repeated")
        let invalid = ProxyConfiguration(
            kind: .http, host: "bad host", port: 8080, username: "login"
        )
        let plan = BulkProxyReassignmentPlan.resolve(
            selectedProfiles: [selected, selected],
            targets: [.init(profileID: selected.id, proxy: invalid)]
        )

        #expect(!plan.isComplete)
        #expect(plan.rows.map(\.issues) == [
            [.invalidTarget], [.duplicateSelectedProfile, .invalidTarget],
        ])
    }

    @Test
    func summariesNeverContainProxyCredentials() {
        let secretMarker = "private-login-marker"
        let profile = profile("Profile")
        let plan = BulkProxyReassignmentPlan.resolve(
            selectedProfiles: [profile],
            targets: [.init(
                profileID: profile.id,
                proxy: proxy(host: "proxy.example", username: secretMarker)
            )]
        )

        let row = try! #require(plan.rows.first)
        let summary = try! #require(row.targetProxy).displayText
        #expect(!summary.contains(secretMarker))
        #expect(!String(describing: plan).contains(secretMarker))
        #expect(summary == "HTTP · proxy.example:8080 · с авторизацией")
    }

    @Test
    func invalidHostUserInfoNeverAppearsInSummaryOrReflection() {
        let secret = "embedded-secret-marker"
        let profile = profile("Profile")
        let plan = BulkProxyReassignmentPlan.resolve(
            selectedProfiles: [profile],
            targets: [.init(
                profileID: profile.id,
                proxy: proxy(host: "login:\(secret)@proxy.example")
            )]
        )

        #expect(!plan.isComplete)
        #expect(!String(describing: plan).contains(secret))
        #expect(plan.rows[0].targetProxy?.endpoint == "некорректный адрес")
    }

    private func profile(_ name: String, revision: UInt64 = 0) -> BrowserProfile {
        BrowserProfile(name: name, revision: revision)
    }

    private func proxy(host: String, username: String = "") -> ProxyConfiguration {
        ProxyConfiguration(kind: .http, host: host, port: 8080, username: username)
    }
}
